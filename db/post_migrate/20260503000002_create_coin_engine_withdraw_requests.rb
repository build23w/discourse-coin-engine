# frozen_string_literal: true

# v0.11.0 - User-initiated withdraw requests. Below the 20K threshold an auto-
# payout won't fire, so users press "Request payment" in the FAB wallet dropdown
# and an admin processes it manually via the admin coin-engine tab.
#
# Rate-limited 1 / 48h per user via Discourse's RateLimiter (in the controller),
# but the table also has a unique partial index so a double-click race can't
# leave two pending rows.
class CreateCoinEngineWithdrawRequests < ActiveRecord::Migration[7.0]
  def up
    create_table :coin_engine_withdraw_requests do |t|
      t.integer  :user_id,        null: false
      t.integer  :amount,         null: false   # snapshot of withdrawable $RENO at request time
      t.string   :status,         null: false, limit: 16, default: 'pending'  # pending|approved|rejected|cancelled
      t.string   :wallet_address, null: false, limit: 64                       # snapshot - may differ from current
      t.text     :user_note
      t.text     :admin_note
      t.integer  :decided_by_user_id
      t.integer  :payment_id        # set when status='approved' and an admin payment was minted
      t.datetime :decided_at
      t.timestamps
    end

    add_index :coin_engine_withdraw_requests, :user_id
    add_index :coin_engine_withdraw_requests, :status
    add_index :coin_engine_withdraw_requests, :created_at
    # One pending request per user at a time
    add_index :coin_engine_withdraw_requests, [:user_id, :status],
      unique: true,
      where: "status = 'pending'",
      name: 'idx_coin_engine_withdraw_one_pending_per_user'
  end

  def down
    drop_table :coin_engine_withdraw_requests
  end
end
