# frozen_string_literal: true

# v0.21.0 — One row per admin-triggered staker-yield distribution.
#
# Lifecycle:
#   pending   — row created, snapshot not yet taken
#   computed  — snapshot done, payout rows inserted
#   completed — every payout either claimed or marked failed
#   failed    — snapshot/compute step blew up; safe to retry by deleting + recreating
#
# Unique on period_label so the same "May-2026" can't be distributed twice
# by accident.

module DiscourseCoinEngine
  class StakeDistribution < ::ActiveRecord::Base
    self.table_name = 'coin_engine_stake_distributions'

    STATUSES = %w[pending computed completed failed].freeze

    has_many   :payouts,
               class_name: 'DiscourseCoinEngine::StakePayout',
               foreign_key: :distribution_id,
               dependent: :destroy
    belongs_to :admin_user, class_name: '::User', foreign_key: :admin_user_id

    validates :period_label, presence: true, uniqueness: true, length: { maximum: 60 }
    validates :total_amount, presence: true, numericality: { only_integer: true, greater_than: 0 }
    validates :status,       inclusion: { in: STATUSES }

    scope :recent, -> { order(created_at: :desc) }
    scope :open,   -> { where(status: %w[pending computed]) }

    def serialize_admin
      {
        id:                    id,
        period_label:          period_label,
        total_amount:          total_amount,
        stakers_count:         stakers_count,
        total_stake_lamports:  total_stake_lamports,
        status:                status,
        started_at:            started_at,
        completed_at:          completed_at,
        admin_user_id:         admin_user_id,
        admin_username:        admin_user&.username,
        notes:                 notes,
        created_at:            created_at,
        claimed_count:         payouts.where(status: 'claimed').count,
        pending_count:         payouts.where(status: 'pending').count,
      }
    end
  end
end
