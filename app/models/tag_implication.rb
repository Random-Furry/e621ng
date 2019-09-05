class TagImplication < TagRelationship
  extend Memoist

  array_attribute :descendant_names

  before_save :update_descendant_names
  after_save :update_descendant_names_for_parents
  after_destroy :update_descendant_names_for_parents
  after_save :create_mod_action
  validates :antecedent_name, uniqueness: { scope: [:consequent_name, :status], conditions: -> { active } }
  validate :absence_of_circular_relation
  validate :absence_of_transitive_relation
  validate :antecedent_is_not_aliased
  validate :consequent_is_not_aliased
  validate :wiki_pages_present, on: :create, unless: :skip_secondary_validations
  scope :old, ->{where("created_at between ? and ?", 2.months.ago, 1.month.ago)}

  module DescendantMethods
    extend ActiveSupport::Concern
    extend Memoist

    module ClassMethods
      # assumes names are normalized
      def with_descendants(names)
        (names + active.where(antecedent_name: names).flat_map(&:descendant_names)).uniq
      end

      def descendants_with_originals(names)
        active.where(antecedent_name: names).map { |x| [x.antecedent_name, x.descendant_names] }.uniq
      end

      def automatic_tags_for(names)
        # TODO: Remove this?
        tags = []
        tags.uniq
      end
    end

    def descendants
      [].tap do |all|
        children = [consequent_name]

        until children.empty?
          all.concat(children)
          children = TagImplication.active.where(antecedent_name: children).pluck(:consequent_name)
        end
      end.sort.uniq
    end
    memoize :descendants

    def update_descendant_names
      self.descendant_names = descendants
    end

    def update_descendant_names!
      flush_cache
      update_descendant_names
      update_attribute(:descendant_names, descendant_names)
    end

    def update_descendant_names_for_parents
      parents.each do |parent|
        parent.update_descendant_names!
        parent.update_descendant_names_for_parents
      end
    end
  end

  module ParentMethods
    extend Memoist

    def parents
      self.class.where("consequent_name = ?", antecedent_name)
    end
    memoize :parents
  end

  module ValidationMethods
    def absence_of_circular_relation
      # We don't want a -> b && b -> a chains
      if descendants.include?(antecedent_name)
        errors[:base] << "Tag implication can not create a circular relation with another tag implication"
      end
    end

    # If we already have a -> b -> c, don't allow a -> c.
    def absence_of_transitive_relation
      # Find everything else the antecedent implies, not including the current implication.
      implications = TagImplication.active.where("antecedent_name = ? and consequent_name != ?", antecedent_name, consequent_name)
      implied_tags = implications.flat_map(&:descendant_names)
      if implied_tags.include?(consequent_name)
        errors[:base] << "#{antecedent_name} already implies #{consequent_name} through another implication"
      end
    end

    def antecedent_is_not_aliased
      # We don't want to implicate a -> b if a is already aliased to c
      if TagAlias.active.exists?(["antecedent_name = ?", antecedent_name])
        errors[:base] << "Antecedent tag must not be aliased to another tag"
      end
    end

    def consequent_is_not_aliased
      # We don't want to implicate a -> b if b is already aliased to c
      if TagAlias.active.exists?(["antecedent_name = ?", consequent_name])
        errors[:base] << "Consequent tag must not be aliased to another tag"
      end
    end

    def wiki_pages_present
      if consequent_wiki.blank?
        errors[:base] << "The #{consequent_name} tag needs a corresponding wiki page"
      end

      if antecedent_wiki.blank?
        errors[:base] << "The #{antecedent_name} tag needs a corresponding wiki page"
      end
    end
  end

  module ApprovalMethods
    extend Memoist

    def process!(update_topic: true)
      unless valid?
        raise errors.full_messages.join("; ")
      end

      tries = 0

      begin
        CurrentUser.scoped(approver) do
          update(status: "processing")
          update_posts
          update(status: "active")
          update_descendant_names_for_parents
          forum_updater.update(approval_message(approver), "APPROVED") if update_topic
        end
      rescue Exception => e
        if tries < 5
          tries += 1
          sleep 2 ** tries
          retry
        end

        forum_updater.update(failure_message(e), "FAILED") if update_topic
        update(status: "error: #{e}")

        DanbooruLogger.log(e, tag_implication_id: id, antecedent_name: antecedent_name, consequent_name: consequent_name)
      end
    end

    def update_posts
      Post.without_timeout do
        Post.sql_raw_tag_match(antecedent_name).find_each do |post|
          fixed_tags = "#{post.tag_string} #{descendant_names_string}".strip
          CurrentUser.scoped(creator, creator_ip_addr) do
            post.update_attributes(
              :tag_string => fixed_tags
            )
          end
        end
      end
    end

    def approve!(approver: CurrentUser.user, update_topic: true)
      update(status: "queued", approver_id: approver.id)
      TagImplicationJob.perform_later(id, update_topic)
    end

    def reject!(update_topic: true)
      update(status: "deleted")
      forum_updater.update(reject_message(CurrentUser.user), "REJECTED") if update_topic
    end

    def create_mod_action
      implication = %Q("tag implication ##{id}":[#{Rails.application.routes.url_helpers.tag_implication_path(self)}]: [[#{antecedent_name}]] -> [[#{consequent_name}]])

      if saved_change_to_id?
        ModAction.log(:tag_implication_create, {implication_id: id, implication_desc: implication})
      else
        # format the changes hash more nicely.
        change_desc = saved_changes.except(:updated_at).map do |attribute, values|
          old, new = values[0], values[1]
          if old.nil?
            %Q(set #{attribute} to "#{new}")
          else
            %Q(changed #{attribute} from "#{old}" to "#{new}")
          end
        end.join(", ")

        ModAction.log(:tag_implication_update, {implication_id: id, implication_desc: implication, change_desc: change_desc})
      end
    end

    def forum_updater
      post = if forum_topic
        forum_post || forum_topic.posts.where("body like ?", TagImplicationRequest.command_string(antecedent_name, consequent_name, id) + "%").last
      else
        nil
      end
      ForumUpdater.new(
        forum_topic,
        forum_post: post,
        expected_title: TagImplicationRequest.topic_title(antecedent_name, consequent_name),
        skip_update: !TagRelationship::SUPPORT_HARD_CODED
      )
    end
    memoize :forum_updater
  end

  include DescendantMethods
  include ParentMethods
  include ValidationMethods
  include ApprovalMethods

  concerning :EmbeddedText do
    class_methods do
      def embedded_pattern
        /\[ti:(?<id>\d+)\]/m
      end
    end
  end

  def reload(options = {})
    flush_cache
    super
  end
end
