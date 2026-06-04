# frozen_string_literal: true

# v0.29.0 — Reddit-style POST vote (table coin_engine_post_votes). One vote per
# (user, post); the feed votes a topic's OP post.
module DiscourseCoinEngine
  class PostVote < ::ActiveRecord::Base
    self.table_name = 'coin_engine_post_votes'

    belongs_to :user, class_name: '::User'

    validates :user_id, :topic_id, :post_id, presence: true
    validates :direction, inclusion: { in: [1, -1] }
    validates :user_id, uniqueness: { scope: :post_id }

    scope :up,   -> { where(direction: 1) }
    scope :down, -> { where(direction: -1) }

    def self.score_for_post(post_id)
      where(post_id: post_id).sum(:direction).to_i
    end

    # Net score of a topic = its OP post's score.
    def self.score_for(topic_id)
      where(topic_id: topic_id).sum(:direction).to_i
    end
  end
end
