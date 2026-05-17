# frozen_string_literal: true

# v0.21.0 — Stake-yield distribution ledger.
#
# Implements the whitepaper §5.2 staker-share mechanism. Admin triggers a
# distribution with (period_label, total_amount, notes). A background job
# snapshots currently-active stakers, computes pro-rata shares weighted by
# amount_lamports, and inserts one coin_engine_stake_payouts row per
# eligible user. Users then claim their payout via the FAB Stake tab, which
# credits gamification_scores from the staking reserve.
#
# IMPORTANT: This system distributes $RENO that is ALREADY ALLOCATED in
# the admin-controlled staking-reward reserve. It does NOT execute any
# open-market buys, on-chain swaps, or external transfers. Pure internal
# accounting moving tokens from a designated reserve to stakers' in-platform
# balances per the disclosed whitepaper terms.

class CreateCoinEngineStakeDistributions < ActiveRecord::Migration[7.0]
  def up
    unless table_exists?(:coin_engine_stake_distributions)
      create_table :coin_engine_stake_distributions do |t|
        t.string   :period_label,         null: false, limit: 60     # e.g. "2026-W22" or "May-2026"
        t.integer  :total_amount,         null: false                # $RENO units (gamification_scores integer)
        t.integer  :stakers_count,        null: false, default: 0    # # of eligible stakers at snapshot
        t.bigint   :total_stake_lamports, null: false, default: 0    # sum of amount_lamports across snapshot
        t.string   :status,               null: false, limit: 16, default: 'pending'  # pending|computed|completed|failed
        t.datetime :started_at
        t.datetime :completed_at
        t.integer  :admin_user_id,        null: false                # who triggered it
        t.text     :notes
        t.timestamps
      end
      add_index :coin_engine_stake_distributions, :period_label, unique: true, name: 'idx_ce_sd_period'
      add_index :coin_engine_stake_distributions, :status,       name: 'idx_ce_sd_status'
      add_index :coin_engine_stake_distributions, :created_at,   name: 'idx_ce_sd_created'
    end

    unless table_exists?(:coin_engine_stake_payouts)
      create_table :coin_engine_stake_payouts do |t|
        t.integer  :distribution_id,                  null: false
        t.integer  :user_id,                          null: false
        t.bigint   :stake_amount_lamports_at_snapshot, null: false   # user's locked lamports at snapshot time
        t.integer  :payout_amount,                    null: false   # $RENO units credited on claim
        t.string   :status,                           null: false, limit: 16, default: 'pending'  # pending|claimed|failed
        t.datetime :claimed_at
        t.text     :notes
        t.timestamps
      end
      add_index :coin_engine_stake_payouts, [:distribution_id, :user_id], unique: true, name: 'idx_ce_sp_unique'
      add_index :coin_engine_stake_payouts, :user_id,                     name: 'idx_ce_sp_user'
      add_index :coin_engine_stake_payouts, [:user_id, :status],          name: 'idx_ce_sp_userstatus'
      add_index :coin_engine_stake_payouts, :distribution_id,             name: 'idx_ce_sp_dist'
    end
  end

  def down
    drop_table :coin_engine_stake_payouts        if table_exists?(:coin_engine_stake_payouts)
    drop_table :coin_engine_stake_distributions  if table_exists?(:coin_engine_stake_distributions)
  end
end
