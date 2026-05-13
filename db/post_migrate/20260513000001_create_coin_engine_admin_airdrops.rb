# frozen_string_literal: true

# v0.20.0 — Admin airdrop ledger.
#
# Every admin-issued airdrop via POST /coin-engine/admin/airdrop.json writes
# one row here. Distinct from coin_engine_random_airdrops (which records the
# scheduled-job random_kindness drops) and from coin_engine_payments (which
# tracks manual_payment receipts via the Payments admin tab).
#
# Tracks the side-effect status of each of the 4 pipeline steps so the admin
# UI can flag partial failures (e.g. credit landed but email didn't).
class CreateCoinEngineAdminAirdrops < ActiveRecord::Migration[7.0]
  def up
    unless table_exists?(:coin_engine_admin_airdrops)
      create_table :coin_engine_admin_airdrops do |t|
        t.integer  :user_id,          null: false               # recipient
        t.integer  :admin_user_id,    null: false               # issuer
        t.integer  :amount,           null: false               # signed; negative = clawback
        t.string   :reason,           limit: 280
        t.string   :source,           limit: 60                 # 'manual' | 'contest' | 'campaign' | ...
        t.boolean  :score_credited,   default: false, null: false
        t.boolean  :ledger_appended,  default: false, null: false
        t.boolean  :email_sent,       default: false, null: false
        t.boolean  :webhook_posted,   default: false, null: false
        t.timestamps
      end
      # Short index names — Postgres 63-char limit per the user_custom_fields lesson.
      add_index :coin_engine_admin_airdrops, :user_id,       name: 'idx_ce_aa_user'
      add_index :coin_engine_admin_airdrops, :admin_user_id, name: 'idx_ce_aa_admin'
      add_index :coin_engine_admin_airdrops, :created_at,    name: 'idx_ce_aa_created'
    end
  end

  def down
    drop_table :coin_engine_admin_airdrops if table_exists?(:coin_engine_admin_airdrops)
  end
end
