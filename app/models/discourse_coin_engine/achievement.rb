# frozen_string_literal: true
module DiscourseCoinEngine
  class Achievement < ::ActiveRecord::Base
    self.table_name = 'coin_engine_achievements'
    belongs_to :user, class_name: '::User'
    validates :slug, presence: true
    validates :user_id, uniqueness: { scope: :slug }
    scope :visible, -> { where(hidden: false) }
  end

  class Tournament < ::ActiveRecord::Base
    self.table_name = 'coin_engine_tournaments'
    has_many :entries, class_name: 'DiscourseCoinEngine::TournamentEntry', foreign_key: :tournament_id
    validates :slug, presence: true, uniqueness: true
    scope :active, -> { where(status: 'active') }
    scope :voting, -> { where(status: 'voting') }
  end

  class TournamentEntry < ::ActiveRecord::Base
    self.table_name = 'coin_engine_tournament_entries'
    belongs_to :tournament, class_name: 'DiscourseCoinEngine::Tournament', foreign_key: :tournament_id
    belongs_to :user,       class_name: '::User'
  end

  class AmaBooking < ::ActiveRecord::Base
    self.table_name = 'coin_engine_ama_bookings'
    belongs_to :user, class_name: '::User'
    validates :title, presence: true
    validates :scheduled_at, presence: true
    scope :upcoming, -> { where(status: 'scheduled').where('scheduled_at > ?', Time.now) }
  end

  class QuestSuggestion < ::ActiveRecord::Base
    self.table_name = 'coin_engine_quest_suggestions'
    belongs_to :suggester, class_name: '::User', foreign_key: :suggester_user_id
    validates :title, presence: true
    validates :description, presence: true
    scope :pending, -> { where(status: 'pending') }
  end

  class PhotoBounty < ::ActiveRecord::Base
    self.table_name = 'coin_engine_photo_bounties'
    belongs_to :poster, class_name: '::User', foreign_key: :poster_user_id
    scope :active, -> { where(status: 'active') }
  end
end
