# frozen_string_literal: true

# v0.12.0 - Records every store purchase + $RENO presale purchase.
#
# currency:
#   reno  - paid with in-platform $RENO (gamification_score debit)
#   sol   - paid with SOL on-chain via Phantom signing
#
# status:
#   pending      - intent recorded, awaiting payment confirmation
#   paid         - $RENO debited OR SOL tx confirmed on-chain
#   fulfilled    - NFT/perk delivered (mint transferred OR perk granted)
#   refunded     - admin refunded the user
#   cancelled    - user/admin cancelled before payment
#   failed       - on-chain tx failed or expired

class CreateCoinEngineStorePurchases < ActiveRecord::Migration[7.0]
  def up
    create_table :coin_engine_store_purchases do |t|
      t.integer  :user_id,      null: false
      t.integer  :item_id                                  # nullable for $RENO presale (no item)
      t.string   :kind,         null: false, limit: 16    # 'item' | 'reno_presale' | 'reno_swap'
      t.string   :currency,     null: false, limit: 8     # 'reno' | 'sol'
      t.bigint   :amount_paid,  null: false, default: 0   # raw amount: $RENO whole units OR lamports
      t.bigint   :amount_received, null: false, default: 0 # for reno purchases (token units delivered)
      t.string   :wallet_used,  limit: 64                  # the user's wallet at time of purchase
      t.string   :tx_signature, limit: 100                 # Solana tx sig (for sol purchases)
      t.string   :status,       null: false, limit: 16, default: 'pending'
      t.text     :metadata_json
      t.datetime :paid_at
      t.datetime :fulfilled_at
      t.timestamps
    end

    add_index :coin_engine_store_purchases, :user_id
    add_index :coin_engine_store_purchases, :item_id
    add_index :coin_engine_store_purchases, :status
    add_index :coin_engine_store_purchases, [:user_id, :status]
    add_index :coin_engine_store_purchases, :tx_signature, unique: true, where: "tx_signature IS NOT NULL"
  end

  def down
    drop_table :coin_engine_store_purchases
  end
end
