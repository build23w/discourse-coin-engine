# frozen_string_literal: true

# v0.12.2 - User stakes via Phantom-signed SOL transfer to the staking
# treasury. Stakes don't change in-platform $RENO score; they're an on-chain
# commitment that gets recorded here for audit + UI display.
#
# Lifecycle:
#   pending      -> awaiting on-chain confirmation of the stake tx
#   active       -> verified on-chain, currently locked
#   unstaking    -> user requested unstake, awaiting cool-down window
#   completed    -> unstaked, returned to user (admin records the return tx)
#   failed       -> on-chain tx never landed or didn't match
#   cancelled    -> user/admin cancelled before payment

class CreateCoinEngineStakes < ActiveRecord::Migration[7.0]
  def up
    create_table :coin_engine_stakes do |t|
      t.integer  :user_id,         null: false
      t.bigint   :amount_lamports, null: false   # SOL amount staked, in lamports
      t.string   :wallet_address,  null: false, limit: 64
      t.string   :stake_tx,        limit: 100              # Solana tx sig of the stake transfer
      t.string   :unstake_tx,      limit: 100              # admin-recorded return tx
      t.string   :status,          null: false, limit: 16, default: 'pending'
      t.integer  :duration_days,   null: false, default: 30 # configured lock duration
      t.datetime :locked_until                              # earliest unstake-eligible date
      t.datetime :confirmed_at                              # when stake_tx was verified
      t.datetime :unstaked_at                               # when admin recorded the return
      t.text     :metadata_json
      t.timestamps
    end

    add_index :coin_engine_stakes, :user_id
    add_index :coin_engine_stakes, :status
    add_index :coin_engine_stakes, [:user_id, :status]
    add_index :coin_engine_stakes, :stake_tx, unique: true, where: "stake_tx IS NOT NULL"
  end

  def down
    drop_table :coin_engine_stakes
  end
end
