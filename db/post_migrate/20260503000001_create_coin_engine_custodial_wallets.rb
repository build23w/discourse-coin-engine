# frozen_string_literal: true

# v0.11.0 - Server-side custodial wallets for users who don't bring their own.
# Stores the encrypted 64-byte Solana secret key. Public key lives on user_field 1
# (existing). encrypted_secret + iv + salt + auth_tag are AES-256-GCM components.
#
# Privacy / threat model:
#   - Encryption key is derived from SiteSetting.coin_engine_wallet_encryption_passphrase
#     via PBKDF2-SHA256 (200k iters) + per-row 16-byte salt
#   - Without the passphrase, ciphertext is useless. Admin sets passphrase out-of-band.
#   - Source of generation tracked: 'signup_browser' = web3.js client-side
#                                   'backfill_server' = Ruby Ed25519
#                                   'admin_regen' = re-issued via admin tool
#   - exported_at: nullable timestamp; set whenever the user downloads their JSON
#   - revoked_at: admin can revoke a custodial wallet (e.g. user took self-custody)
class CreateCoinEngineCustodialWallets < ActiveRecord::Migration[7.0]
  def up
    create_table :coin_engine_custodial_wallets do |t|
      t.integer  :user_id,           null: false
      t.string   :public_key,        null: false, limit: 64
      t.binary   :encrypted_secret,  null: false
      t.binary   :iv,                null: false, limit: 12
      t.binary   :auth_tag,          null: false, limit: 16
      t.binary   :salt,              null: false, limit: 16
      t.string   :source,            null: false, limit: 32, default: 'unknown'
      t.datetime :exported_at
      t.integer  :export_count,      null: false, default: 0
      t.datetime :revoked_at
      t.string   :revoked_reason,    limit: 200
      t.timestamps
    end

    add_index :coin_engine_custodial_wallets, :user_id,    unique: true
    add_index :coin_engine_custodial_wallets, :public_key, unique: true
    add_index :coin_engine_custodial_wallets, :revoked_at
  end

  def down
    drop_table :coin_engine_custodial_wallets
  end
end
