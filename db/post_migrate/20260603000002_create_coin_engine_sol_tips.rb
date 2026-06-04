# frozen_string_literal: true

# v0.27.0 — peer-to-peer on-chain SOL tips. The sender's Phantom signs a SOL
# transfer DIRECTLY to the recipient's linked wallet (not a treasury); we record
# the intent and verify the transaction landed on-chain.
class CreateCoinEngineSolTips < ActiveRecord::Migration[7.0]
  def up
    return if table_exists?(:coin_engine_sol_tips)
    create_table :coin_engine_sol_tips do |t|
      t.integer  :sender_user_id,    null: false
      t.integer  :recipient_user_id, null: false
      t.bigint   :amount_lamports,   null: false
      t.string   :recipient_wallet,  null: false, limit: 64
      t.string   :tx_signature,      limit: 100
      t.string   :status,            null: false, limit: 16, default: 'pending'
      t.integer  :post_id
      t.string   :memo,              limit: 120
      t.datetime :confirmed_at
      t.text     :metadata_json
      t.timestamps
    end
    add_index :coin_engine_sol_tips, :sender_user_id
    add_index :coin_engine_sol_tips, :recipient_user_id
    add_index :coin_engine_sol_tips, :status
    add_index :coin_engine_sol_tips, :tx_signature, unique: true, where: "tx_signature IS NOT NULL", name: 'idx_ce_sol_tip_sig'
  end

  def down
    drop_table :coin_engine_sol_tips if table_exists?(:coin_engine_sol_tips)
  end
end
