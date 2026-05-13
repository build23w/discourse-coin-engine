# frozen_string_literal: true

# v0.20.0 — Admin airdrop ledger row.
#
# Persisted record of every admin-issued airdrop via
# POST /coin-engine/admin/airdrop.json. Powers the Airdrops admin tab.
module DiscourseCoinEngine
  class AdminAirdrop < ::ActiveRecord::Base
    self.table_name = 'coin_engine_admin_airdrops'

    belongs_to :user,       class_name: '::User'
    belongs_to :admin_user, class_name: '::User', foreign_key: :admin_user_id

    validates :user_id,       presence: true
    validates :admin_user_id, presence: true
    validates :amount,        presence: true, numericality: { only_integer: true }

    scope :recent, -> { order(created_at: :desc) }
  end
end
