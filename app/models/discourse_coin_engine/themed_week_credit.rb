# frozen_string_literal: true

# v0.17.0 — Records each themed-week bonus that fired. The unique index on
# post_id is what makes the dispatcher idempotent.
module DiscourseCoinEngine
  class ThemedWeekCredit < ::ActiveRecord::Base
    self.table_name = 'coin_engine_themed_week_credits'

    MATCH_KINDS = %w[category hashtag both].freeze

    belongs_to :user, class_name: '::User'
    belongs_to :post, class_name: '::Post', optional: true

    validates :post_id,          presence: true, uniqueness: true
    validates :user_id,          presence: true
    validates :themed_week_name, presence: true, length: { maximum: 100 }
    validates :amount,           numericality: { greater_than_or_equal_to: 0 }
    validates :match_kind,       inclusion: { in: MATCH_KINDS }

    scope :recent, -> { order(created_at: :desc) }
    scope :for_theme, ->(name) { where(themed_week_name: name) }
  end
end
