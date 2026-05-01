# frozen_string_literal: true

# v0.6.0 Phase 2 — Economy primitives (Tips, Shop, Bounties, Stakes)
class CreateCoinEnginePhase2Tables < ActiveRecord::Migration[7.0]
  def up
    unless table_exists?(:coin_engine_tips)
      create_table :coin_engine_tips do |t|
        t.integer :sender_user_id,    null: false
        t.integer :recipient_user_id, null: false
        t.integer :post_id           # optional: tip pinned to a specific post
        t.integer :amount,           null: false
        t.string  :note,             limit: 280
        t.string  :status,           null: false, default: 'sent'  # sent | refunded
        t.timestamps
      end
      add_index :coin_engine_tips, :sender_user_id
      add_index :coin_engine_tips, :recipient_user_id
      add_index :coin_engine_tips, :post_id
      add_index :coin_engine_tips, :created_at
    end

    unless table_exists?(:coin_engine_shop_items)
      create_table :coin_engine_shop_items do |t|
        t.string  :slug,        null: false
        t.string  :name,        null: false
        t.text    :description
        t.string  :icon,        limit: 64       # emoji or short label
        t.integer :price,       null: false
        t.string  :item_type,   null: false      # title|frame|background|spotlight|halo|color
        t.text    :payload                       # JSON: e.g. {"title":"Diamond Dog","duration_days":30}
        t.integer :stock,       default: -1     # -1 = unlimited
        t.boolean :enabled,     default: true
        t.integer :sort_order,  default: 0
        t.timestamps
      end
      add_index :coin_engine_shop_items, :slug, unique: true
      add_index :coin_engine_shop_items, :enabled
      add_index :coin_engine_shop_items, :item_type
    end

    unless table_exists?(:coin_engine_redemptions)
      create_table :coin_engine_redemptions do |t|
        t.integer :user_id,      null: false
        t.integer :shop_item_id, null: false
        t.integer :price_paid,   null: false
        t.text    :payload                       # snapshot of shop item payload
        t.datetime :expires_at                   # for time-limited cosmetics
        t.string  :status,       null: false, default: 'active'  # active|expired|revoked
        t.timestamps
      end
      add_index :coin_engine_redemptions, :user_id
      add_index :coin_engine_redemptions, :shop_item_id
      add_index :coin_engine_redemptions, :status
      add_index :coin_engine_redemptions, :expires_at
    end

    unless table_exists?(:coin_engine_bounties)
      create_table :coin_engine_bounties do |t|
        t.integer :poster_user_id, null: false
        t.integer :topic_id,       null: false
        t.integer :post_id                       # original post the bounty pins to
        t.integer :amount,         null: false
        t.string  :status,         null: false, default: 'open'  # open|awarded|expired|cancelled
        t.integer :winner_user_id
        t.integer :winning_post_id
        t.datetime :expires_at
        t.datetime :awarded_at
        t.text    :note
        t.timestamps
      end
      add_index :coin_engine_bounties, :poster_user_id
      add_index :coin_engine_bounties, :topic_id
      add_index :coin_engine_bounties, :status
      add_index :coin_engine_bounties, :expires_at
    end

    unless table_exists?(:coin_engine_stakes)
      create_table :coin_engine_stakes do |t|
        t.integer :user_id,    null: false
        t.integer :amount,     null: false
        t.integer :duration_days, null: false       # 7, 30, 90
        t.float   :multiplier, null: false           # 1.1, 1.25, 1.5
        t.datetime :stakes_at, null: false
        t.datetime :unlocks_at, null: false
        t.string  :status,     null: false, default: 'active'  # active|matured|early_unlocked
        t.integer :rewards_paid, default: 0
        t.timestamps
      end
      add_index :coin_engine_stakes, :user_id
      add_index :coin_engine_stakes, :status
      add_index :coin_engine_stakes, :unlocks_at
    end
  end

  def down
    drop_table :coin_engine_stakes      if table_exists?(:coin_engine_stakes)
    drop_table :coin_engine_bounties    if table_exists?(:coin_engine_bounties)
    drop_table :coin_engine_redemptions if table_exists?(:coin_engine_redemptions)
    drop_table :coin_engine_shop_items  if table_exists?(:coin_engine_shop_items)
    drop_table :coin_engine_tips        if table_exists?(:coin_engine_tips)
  end
end
