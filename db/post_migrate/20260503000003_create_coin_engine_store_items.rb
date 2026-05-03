# frozen_string_literal: true

# v0.12.0 - Storefront for NFTs and digital perks paid in $RENO or SOL.
#
# kind values:
#   nft       - on-chain NFT (mint_address required for fulfillment)
#   perk      - in-platform perk (custom title, badge, theme variant, etc.)
#   bundle    - bag of $RENO + perk + NFT
#   presale   - virtual product representing $RENO purchased via presale
#
# Currency model:
#   price_reno > 0  -> can buy with $RENO (debits gamification balance)
#   price_sol  > 0  -> can buy with SOL via Phantom (transfer to treasury)
#   either or both can be set; UI shows whichever payment paths are available.

class CreateCoinEngineStoreItems < ActiveRecord::Migration[7.0]
  def up
    create_table :coin_engine_store_items do |t|
      t.string   :kind,             null: false, limit: 16,  default: 'nft'
      t.string   :name,             null: false, limit: 120
      t.string   :slug,             null: false, limit: 140
      t.text     :description
      t.string   :image_url,        limit: 600
      t.string   :mint_address,     limit: 64               # Solana mint pubkey, nullable until minted
      t.integer  :price_reno,       null: false, default: 0
      t.bigint   :price_sol_lamports, null: false, default: 0   # 1 SOL = 1_000_000_000 lamports
      t.integer  :supply,           null: false, default: 1   # 0 = unlimited; >0 = max copies
      t.integer  :sold_count,       null: false, default: 0
      t.integer  :position,         null: false, default: 0   # display order
      t.boolean  :active,           null: false, default: true
      t.boolean  :featured,         null: false, default: false
      t.text     :traits_json                                # arbitrary metadata for badges/perks
      t.integer  :created_by_user_id
      t.datetime :released_at
      t.datetime :expires_at
      t.timestamps
    end

    add_index :coin_engine_store_items, :slug,    unique: true
    add_index :coin_engine_store_items, :kind
    add_index :coin_engine_store_items, [:active, :position]
    add_index :coin_engine_store_items, :featured, where: "featured = true"
    add_index :coin_engine_store_items, :mint_address, where: "mint_address IS NOT NULL"
  end

  def down
    drop_table :coin_engine_store_items
  end
end
