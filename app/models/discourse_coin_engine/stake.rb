# frozen_string_literal: true

module DiscourseCoinEngine
  class Stake < ::ActiveRecord::Base
    self.table_name = 'coin_engine_stakes'

    STATUSES = %w[pending active unstaking completed failed cancelled].freeze

    belongs_to :user, class_name: '::User'

    validates :user_id,         presence: true
    validates :amount_lamports, numericality: { greater_than: 0 }
    validates :wallet_address,  presence: true, length: { maximum: 64 }
    validates :status,          inclusion: { in: STATUSES }
    validates :duration_days,   numericality: { greater_than: 0, less_than_or_equal_to: 365 }

    scope :recent,     -> { order(created_at: :desc) }
    scope :active,     -> { where(status: 'active') }
    scope :pending,    -> { where(status: 'pending') }
    scope :for_user,   ->(uid) { where(user_id: uid) }

    def amount_sol
      amount_lamports.to_f / 1_000_000_000
    end

    def unlockable?
      locked_until.nil? || locked_until <= Time.zone.now
    end

    def days_until_unlock
      return 0 if unlockable?
      ((locked_until - Time.zone.now) / 1.day).ceil
    end

    def metadata
      return {} if metadata_json.blank?
      JSON.parse(metadata_json) rescue {}
    end

    def serialize_for_user
      {
        id:              id,
        amount_lamports: amount_lamports.to_i,
        amount_sol:      amount_sol,
        wallet_address:  wallet_address,
        stake_tx:        stake_tx,
        unstake_tx:      unstake_tx,
        status:          status,
        duration_days:   duration_days,
        locked_until:    locked_until,
        confirmed_at:    confirmed_at,
        unstaked_at:     unstaked_at,
        unlockable:      unlockable?,
        days_until_unlock: days_until_unlock,
        created_at:      created_at,
      }
    end
  end
end
