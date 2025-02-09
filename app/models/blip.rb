class Blip < ApplicationRecord
  include UserWarnable
  simple_versioning
  belongs_to_creator
  user_status_counter :blip_count
  validates :body, presence: true
  belongs_to :parent, class_name: "Blip", foreign_key: "response_to", optional: true
  has_many :responses, class_name: "Blip", foreign_key: "response_to"
  validates :body, length: { minimum: 5, maximum: Danbooru.config.blip_max_size }
  validate :validate_parent_exists, :on => :create
  validate :validate_creator_is_not_limited, :on => :create

  def response?
    parent.present?
  end

  def has_responses?
    responses.any?
  end

  def validate_creator_is_not_limited
    allowed = creator.can_blip_with_reason
    if allowed != true
      errors.add(:creator, User.throttle_reason(allowed))
      return false
    end
    true
  end

  def validate_parent_exists
    if response_to.present?
      errors.add(:response_to, "must exist") unless Blip.exists?(response_to)
    end
  end

  module ApiMethods
    def method_attributes
      super + [:creator_name]
    end
  end

  module PermissionsMethods
    def can_edit?(user)
      return true if user.is_admin?
      return false if was_warned?
      creator_id == user.id && created_at > 5.minutes.ago
    end

    def can_hide?(user)
      return true if user.is_moderator?
      return false if was_warned?
      user.id == creator_id
    end

    def visible_to?(user)
      return true unless is_hidden
      user.is_moderator? || user.id == creator_id
    end
  end

  module SearchMethods
    def visible(user = CurrentUser)
      if user.is_moderator?
        all
      else
        where('is_hidden = ?', false)
      end
    end

    def for_creator(user_id)
      user_id.present? ? where("creator_id = ?", user_id) : none
    end

    def search(params)
      q = super

      q = q.includes(:creator).includes(:responses).includes(:parent)

      q = q.attribute_matches(:body, params[:body_matches])

      if params[:response_to].present?
        q = q.where('response_to = ?', params[:response_to].to_i)
      end

      q = q.where_user(:creator_id, :creator, params)

      if params[:ip_addr].present?
        q = q.where("creator_ip_addr <<= ?", params[:ip_addr])
      end

      case params[:order]
      when "updated_at", "updated_at_desc"
        q = q.order("blips.updated_at DESC")
      else
        q = q.apply_basic_order(params)
      end

      q
    end
  end

  include PermissionsMethods
  extend SearchMethods
  include ApiMethods
end
