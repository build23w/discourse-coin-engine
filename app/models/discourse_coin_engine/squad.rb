# frozen_string_literal: true
module DiscourseCoinEngine
  class Squad < ::ActiveRecord::Base
    self.table_name = 'coin_engine_squads'
    has_many :memberships, class_name: 'DiscourseCoinEngine::SquadMembership', foreign_key: :squad_id
    validates :slug, presence: true, uniqueness: true
    validates :name, presence: true
    scope :enabled, -> { where(enabled: true) }
  end

  class SquadMembership < ::ActiveRecord::Base
    self.table_name = 'coin_engine_squad_memberships'
    belongs_to :squad, class_name: 'DiscourseCoinEngine::Squad', foreign_key: :squad_id
    belongs_to :user,  class_name: '::User'
    validates :user_id, uniqueness: { scope: :squad_id }
  end

  class Mentorship < ::ActiveRecord::Base
    self.table_name = 'coin_engine_mentorships'
    belongs_to :mentor, class_name: '::User', foreign_key: :mentor_user_id
    belongs_to :mentee, class_name: '::User', foreign_key: :mentee_user_id
    validates :mentee_user_id, uniqueness: { scope: :mentor_user_id }
    scope :active, -> { where(status: 'active') }
  end

  class Spotlight < ::ActiveRecord::Base
    self.table_name = 'coin_engine_spotlights'
    belongs_to :user, class_name: '::User'
    belongs_to :post, class_name: '::Post', optional: true
    belongs_to :topic, class_name: '::Topic', optional: true
  end
end
