# frozen_string_literal: true

# v0.10.0 — Extend coin_engine_bounties to support random_reach mode
# (DM-targeted bounties picked from online users) and add claim/invitation
# tracking tables.
#
# bounty_type:
#   'manual'        — legacy: poster manually picks winner via award_bounty (default for back-compat)
#   'random_reach'  — system picks K online users, DMs them; first to reply wins
#
# Future-reserved values: 'first_comment' (FCFS) and 'crowd_split' (pool-divide).

class ExtendCoinEngineBountiesRandomReach < ActiveRecord::Migration[7.0]
  def up
    if table_exists?(:coin_engine_bounties)
      add_column :coin_engine_bounties, :bounty_type,       :string,  default: 'manual', null: false unless column_exists?(:coin_engine_bounties, :bounty_type)
      add_column :coin_engine_bounties, :max_winners,       :integer, default: 1,        null: false unless column_exists?(:coin_engine_bounties, :max_winners)
      add_column :coin_engine_bounties, :invite_count,      :integer, default: 5,        null: false unless column_exists?(:coin_engine_bounties, :invite_count)
      add_column :coin_engine_bounties, :window_minutes,    :integer, default: 30,       null: false unless column_exists?(:coin_engine_bounties, :window_minutes)
      add_column :coin_engine_bounties, :invitation_round,  :integer, default: 0,        null: false unless column_exists?(:coin_engine_bounties, :invitation_round)
      add_column :coin_engine_bounties, :claims_count,      :integer, default: 0,        null: false unless column_exists?(:coin_engine_bounties, :claims_count)
      add_column :coin_engine_bounties, :next_round_at,     :datetime                                  unless column_exists?(:coin_engine_bounties, :next_round_at)
      add_index  :coin_engine_bounties, [:bounty_type, :status], name: 'idx_ce_bounties_type_status' unless index_exists?(:coin_engine_bounties, [:bounty_type, :status])
    end

    unless table_exists?(:coin_engine_bounty_invitations)
      create_table :coin_engine_bounty_invitations do |t|
        t.integer  :bounty_id,    null: false
        t.integer  :user_id,      null: false
        t.integer  :round,        null: false, default: 1
        t.datetime :invited_at,   null: false
        t.datetime :responded_at
        t.boolean  :won,          null: false, default: false
        t.timestamps
      end
      add_index :coin_engine_bounty_invitations, [:bounty_id, :user_id], unique: true, name: 'idx_ce_bounty_inv_uniq'
      add_index :coin_engine_bounty_invitations, :user_id,                              name: 'idx_ce_bounty_inv_user'
      add_index :coin_engine_bounty_invitations, :bounty_id,                            name: 'idx_ce_bounty_inv_bounty'
    end

    unless table_exists?(:coin_engine_bounty_claims)
      create_table :coin_engine_bounty_claims do |t|
        t.integer  :bounty_id,       null: false
        t.integer  :user_id,         null: false
        t.integer  :post_id          # the reply that earned the claim
        t.integer  :awarded_amount,  null: false, default: 0
        t.datetime :claimed_at,      null: false
        t.timestamps
      end
      # Atomic guard: one claim per (bounty, user). The race-resolution insert
      # uses ON CONFLICT (bounty_id, user_id) DO NOTHING RETURNING id.
      add_index :coin_engine_bounty_claims, [:bounty_id, :user_id], unique: true, name: 'idx_ce_bounty_claim_uniq'
      add_index :coin_engine_bounty_claims, :user_id,                              name: 'idx_ce_bounty_claim_user'
    end
  end

  def down
    drop_table :coin_engine_bounty_claims      if table_exists?(:coin_engine_bounty_claims)
    drop_table :coin_engine_bounty_invitations if table_exists?(:coin_engine_bounty_invitations)
    if table_exists?(:coin_engine_bounties)
      [:bounty_type, :max_winners, :invite_count, :window_minutes, :invitation_round, :claims_count, :next_round_at].each do |col|
        remove_column :coin_engine_bounties, col if column_exists?(:coin_engine_bounties, col)
      end
    end
  end
end
