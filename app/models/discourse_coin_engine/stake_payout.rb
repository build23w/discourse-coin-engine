# frozen_string_literal: true

# v0.21.0 — One row per (distribution, user) pair. Records the user's
# eligible stake size at snapshot time + their pro-rata $RENO payout.
# Users claim via POST /coin-engine/staking/claim_payout.json, which
# credits gamification_scores from the admin-funded staking reserve.

module DiscourseCoinEngine
  class StakePayout < ::ActiveRecord::Base
    self.table_name = 'coin_engine_stake_payouts'

    STATUSES = %w[pending claimed failed].freeze

    belongs_to :distribution,
               class_name: 'DiscourseCoinEngine::StakeDistribution',
               foreign_key: :distribution_id
    belongs_to :user, class_name: '::User'

    validates :distribution_id, presence: true
    validates :user_id,         presence: true
    validates :payout_amount,   presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :status,          inclusion: { in: STATUSES }

    scope :pending, -> { where(status: 'pending') }
    scope :claimed, -> { where(status: 'claimed') }
    scope :recent,  -> { order(created_at: :desc) }
    scope :for_user, ->(uid) { where(user_id: uid) }

    def serialize_for_user
      {
        id:                                   id,
        distribution_id:                      distribution_id,
        distribution_label:                   distribution&.period_label,
        stake_amount_lamports_at_snapshot:    stake_amount_lamports_at_snapshot.to_i,
        stake_amount_sol_at_snapshot:         stake_amount_lamports_at_snapshot.to_f / 1_000_000_000,
        payout_amount:                        payout_amount.to_i,
        status:                               status,
        claimed_at:                           claimed_at,
        created_at:                           created_at,
      }
    end
  end
end
