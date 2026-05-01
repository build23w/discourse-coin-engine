# frozen_string_literal: true
module DiscourseCoinEngine
  class Vote < ::ActiveRecord::Base
    self.table_name = 'coin_engine_votes'
    has_many :ballots, class_name: 'DiscourseCoinEngine::VoteBallot', foreign_key: :vote_id
    belongs_to :creator, class_name: '::User', foreign_key: :created_by_user_id
    validates :slug, presence: true, uniqueness: true
    validates :title, presence: true
    scope :open, -> { where(status: 'open') }

    def parsed_options
      JSON.parse(options || '[]') rescue []
    end

    def tally
      ballots.group(:option_key).sum(:weight)
    end
  end

  class VoteBallot < ::ActiveRecord::Base
    self.table_name = 'coin_engine_vote_ballots'
    belongs_to :vote, class_name: 'DiscourseCoinEngine::Vote', foreign_key: :vote_id
    belongs_to :user, class_name: '::User'
    validates :user_id, uniqueness: { scope: :vote_id }
  end

  class VerifiedPro < ::ActiveRecord::Base
    self.table_name = 'coin_engine_verified_pros'
    belongs_to :user, class_name: '::User'
    validates :user_id, uniqueness: true
    scope :verified, -> { where(verification_status: 'verified') }
  end
end
