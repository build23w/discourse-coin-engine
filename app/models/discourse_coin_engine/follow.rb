# frozen_string_literal: true
module DiscourseCoinEngine
  class Follow < ::ActiveRecord::Base
    self.table_name = 'coin_engine_follows'
    validates :follower_id, :following_id, presence: true
    validates :follower_id, uniqueness: { scope: :following_id }
  end
end
