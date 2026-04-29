# frozen_string_literal: true

class CreateCoinEnginePayments < ActiveRecord::Migration[7.0]
  def change
    create_table :coin_engine_payments do |t|
      t.integer  :user_id,           null: false
      t.integer  :amount,            null: false
      t.string   :reason,            limit: 500
      t.string   :source,            limit: 50,  null: false, default: 'manual'
      t.string   :status,            limit: 30,  null: false, default: 'approved'
      t.string   :tx_signature,      limit: 200
      t.string   :wallet_address,    limit: 200
      t.integer  :issued_by_user_id
      t.datetime :sent_at
      t.datetime :tx_added_at
      t.timestamps
    end

    add_index :coin_engine_payments, :user_id
    add_index :coin_engine_payments, :status
    add_index :coin_engine_payments, :created_at
    add_index :coin_engine_payments, :tx_signature, unique: true, where: 'tx_signature IS NOT NULL'
  end
end
