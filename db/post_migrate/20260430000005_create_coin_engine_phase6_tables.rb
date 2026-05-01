# frozen_string_literal: true

# v0.6.0 Phase 6 — Surprise & Polish (Daily Chests, Streak Freezes, Auctions)
class CreateCoinEnginePhase6Tables < ActiveRecord::Migration[7.0]
  def up
    unless table_exists?(:coin_engine_daily_chests)
      create_table :coin_engine_daily_chests do |t|
        t.integer :user_id,      null: false
        t.date    :claim_date,   null: false
        t.integer :reward_amount, null: false
        t.string  :reward_type,   null: false  # standard|rare|legendary
        t.string  :rarity_roll,   limit: 16    # for audit (e.g. 'rolled:0.873')
        t.timestamps
      end
      add_index :coin_engine_daily_chests, [:user_id, :claim_date], unique: true, name: 'idx_ce_chest_unique'
    end

    unless table_exists?(:coin_engine_streak_freezes)
      create_table :coin_engine_streak_freezes do |t|
        t.integer :user_id,    null: false
        t.date    :freeze_date, null: false   # the day that was protected
        t.integer :cost_paid,   null: false
        t.timestamps
      end
      add_index :coin_engine_streak_freezes, [:user_id, :freeze_date], unique: true, name: 'idx_ce_freeze_unique'
    end

    unless table_exists?(:coin_engine_auctions)
      create_table :coin_engine_auctions do |t|
        t.string  :slug,       null: false
        t.string  :item_name,  null: false
        t.text    :description
        t.string  :icon,       limit: 64
        t.string  :item_type,  null: false   # title|frame|halo|spotlight
        t.text    :payload
        t.integer :starting_bid, null: false
        t.integer :current_bid,  default: 0
        t.integer :leading_user_id
        t.datetime :starts_at, null: false
        t.datetime :ends_at,   null: false
        t.string  :status,     default: 'upcoming'  # upcoming|live|sold|cancelled
        t.timestamps
      end
      add_index :coin_engine_auctions, :slug, unique: true
      add_index :coin_engine_auctions, :status
      add_index :coin_engine_auctions, :ends_at
    end

    unless table_exists?(:coin_engine_auction_bids)
      create_table :coin_engine_auction_bids do |t|
        t.integer :auction_id, null: false
        t.integer :user_id,    null: false
        t.integer :amount,     null: false
        t.timestamps
      end
      add_index :coin_engine_auction_bids, :auction_id
      add_index :coin_engine_auction_bids, [:auction_id, :amount], name: 'idx_ce_bid_amount'
    end

    unless table_exists?(:coin_engine_random_airdrops)
      create_table :coin_engine_random_airdrops do |t|
        t.integer :user_id,    null: false
        t.integer :amount,     null: false
        t.date    :airdrop_date, null: false
        t.string  :reason,     default: 'random_kindness'
        t.timestamps
      end
      add_index :coin_engine_random_airdrops, [:user_id, :airdrop_date], unique: true, name: 'idx_ce_airdrop_unique'
    end
  end

  def down
    drop_table :coin_engine_random_airdrops  if table_exists?(:coin_engine_random_airdrops)
    drop_table :coin_engine_auction_bids     if table_exists?(:coin_engine_auction_bids)
    drop_table :coin_engine_auctions         if table_exists?(:coin_engine_auctions)
    drop_table :coin_engine_streak_freezes   if table_exists?(:coin_engine_streak_freezes)
    drop_table :coin_engine_daily_chests     if table_exists?(:coin_engine_daily_chests)
  end
end
