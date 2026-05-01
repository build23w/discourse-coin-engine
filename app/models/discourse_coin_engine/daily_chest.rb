# frozen_string_literal: true
module DiscourseCoinEngine
  class DailyChest < ::ActiveRecord::Base
    self.table_name = 'coin_engine_daily_chests'
    belongs_to :user, class_name: '::User'
    validates :user_id, uniqueness: { scope: :claim_date }
  end

  class StreakFreeze < ::ActiveRecord::Base
    self.table_name = 'coin_engine_streak_freezes'
    belongs_to :user, class_name: '::User'
    validates :user_id, uniqueness: { scope: :freeze_date }
  end

  class Auction < ::ActiveRecord::Base
    self.table_name = 'coin_engine_auctions'
    has_many :bids, class_name: 'DiscourseCoinEngine::AuctionBid', foreign_key: :auction_id
    belongs_to :leading_user, class_name: '::User', foreign_key: :leading_user_id, optional: true
    validates :slug, presence: true, uniqueness: true
    scope :live, -> { where(status: 'live') }
    def live?; status == 'live'; end
    def time_remaining; ends_at ? [ends_at - Time.now, 0].max.to_i : 0; end
  end

  class AuctionBid < ::ActiveRecord::Base
    self.table_name = 'coin_engine_auction_bids'
    belongs_to :auction, class_name: 'DiscourseCoinEngine::Auction', foreign_key: :auction_id
    belongs_to :user,    class_name: '::User'
  end

  class RandomAirdrop < ::ActiveRecord::Base
    self.table_name = 'coin_engine_random_airdrops'
    belongs_to :user, class_name: '::User'
    validates :user_id, uniqueness: { scope: :airdrop_date }
  end
end
