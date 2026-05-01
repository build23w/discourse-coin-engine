# frozen_string_literal: true
module DiscourseCoinEngine
  class Bounty < ::ActiveRecord::Base
    self.table_name = 'coin_engine_bounties'
    belongs_to :poster,         class_name: '::User', foreign_key: :poster_user_id
    belongs_to :winner,         class_name: '::User', foreign_key: :winner_user_id, optional: true
    belongs_to :topic,          class_name: '::Topic'
    belongs_to :original_post,  class_name: '::Post',  foreign_key: :post_id, optional: true
    belongs_to :winning_post,   class_name: '::Post',  foreign_key: :winning_post_id, optional: true
    validates :amount, numericality: { greater_than: 0 }
    scope :open,      -> { where(status: 'open') }
    scope :awarded,   -> { where(status: 'awarded') }
    def open?;     status == 'open'; end
    def expired?;  expires_at && expires_at < Time.now; end
  end

  class Stake < ::ActiveRecord::Base
    self.table_name = 'coin_engine_stakes'
    belongs_to :user, class_name: '::User'
    validates :amount,        numericality: { greater_than: 0 }
    validates :duration_days, inclusion: { in: [7, 30, 90, 180] }
    validates :multiplier,    numericality: { greater_than_or_equal_to: 1.0, less_than_or_equal_to: 3.0 }
    scope :active, -> { where(status: 'active') }
    def matured?; status == 'matured' || (unlocks_at && unlocks_at <= Time.now); end
  end
end
