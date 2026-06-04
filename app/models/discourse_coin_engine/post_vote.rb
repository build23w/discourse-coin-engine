# frozen_string_literal: true

# v0.28.0 — Reddit-style topic vote (table coin_engine_post_votes).
module DiscourseCoinEngine
  class PostVote < ::ActiveRecord::Base
    self.table_name = 'coin_engine_post_votes'

    belongs_to :user, class_name: '::User'

    validates :user_id, :topic_id, presence: true
    validates :direction, inclusion: { in: [1, -1] }
    validates :user_id, uniqueness: { scope: :topic_id }

    scope :up,   -> { where(direction: 1) }
    scope :down, -> { where(direction: -1) }

    def self.score_for(topic_id)
      where(topic_id: topic_id).sum(:direction).to_i
    end
  end
end
