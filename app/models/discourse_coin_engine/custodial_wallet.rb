# frozen_string_literal: true

module DiscourseCoinEngine
  class CustodialWallet < ::ActiveRecord::Base
    self.table_name = 'coin_engine_custodial_wallets'

    SOURCES = %w[signup_browser backfill_server admin_regen self_service unknown].freeze

    belongs_to :user, class_name: '::User', optional: true

    validates :user_id,    presence: true, uniqueness: true
    validates :public_key, presence: true, length: { maximum: 64 }, uniqueness: true
    validates :source,     inclusion: { in: SOURCES }

    scope :active,  -> { where(revoked_at: nil) }
    scope :revoked, -> { where.not(revoked_at: nil) }

    def revoked?
      revoked_at.present?
    end

    def mark_exported!
      update_columns(exported_at: Time.zone.now, export_count: export_count.to_i + 1)
    end
  end
end
