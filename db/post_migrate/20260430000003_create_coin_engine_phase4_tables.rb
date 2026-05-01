# frozen_string_literal: true

# v0.6.0 Phase 4 — Identity & Insights (Achievements, Tournaments, AMA, Quest Suggestions, Photo Bounties)
class CreateCoinEnginePhase4Tables < ActiveRecord::Migration[7.0]
  def up
    unless table_exists?(:coin_engine_achievements)
      create_table :coin_engine_achievements do |t|
        t.integer :user_id,    null: false
        t.string  :slug,       null: false   # e.g. 'first_post', 'night_owl', 'centurion'
        t.string  :name,       null: false
        t.text    :description
        t.string  :icon,       limit: 64
        t.integer :reward,     default: 0
        t.boolean :hidden,     default: false   # easter eggs are hidden until earned
        t.datetime :unlocked_at, null: false
        t.timestamps
      end
      add_index :coin_engine_achievements, [:user_id, :slug], unique: true, name: 'idx_ce_ach_unique'
      add_index :coin_engine_achievements, :slug
    end

    unless table_exists?(:coin_engine_tournaments)
      create_table :coin_engine_tournaments do |t|
        t.string  :slug,       null: false
        t.string  :name,       null: false
        t.text    :description
        t.string  :tournament_type, null: false  # best_of_quarter|monthly_theme|head_to_head
        t.datetime :starts_at, null: false
        t.datetime :ends_at,   null: false
        t.string  :status,     default: 'upcoming'  # upcoming|active|voting|completed
        t.integer :prize_pool, default: 0
        t.integer :winner_user_id
        t.integer :winning_topic_id
        t.timestamps
      end
      add_index :coin_engine_tournaments, :slug, unique: true
      add_index :coin_engine_tournaments, :status
      add_index :coin_engine_tournaments, :ends_at
    end

    unless table_exists?(:coin_engine_tournament_entries)
      create_table :coin_engine_tournament_entries do |t|
        t.integer :tournament_id, null: false
        t.integer :user_id,       null: false
        t.integer :topic_id
        t.integer :post_id
        t.integer :vote_count,    default: 0
        t.timestamps
      end
      add_index :coin_engine_tournament_entries, :tournament_id
      add_index :coin_engine_tournament_entries, [:tournament_id, :user_id], name: 'idx_ce_te_user'
    end

    unless table_exists?(:coin_engine_ama_bookings)
      create_table :coin_engine_ama_bookings do |t|
        t.integer :user_id,    null: false
        t.string  :title,      null: false
        t.text    :description
        t.datetime :scheduled_at, null: false
        t.integer :paid_amount, null: false
        t.string  :status,     default: 'scheduled'  # scheduled|live|completed|cancelled
        t.integer :topic_id
        t.timestamps
      end
      add_index :coin_engine_ama_bookings, :user_id
      add_index :coin_engine_ama_bookings, :scheduled_at
      add_index :coin_engine_ama_bookings, :status
    end

    unless table_exists?(:coin_engine_quest_suggestions)
      create_table :coin_engine_quest_suggestions do |t|
        t.integer :suggester_user_id, null: false
        t.string  :title,       null: false
        t.text    :description, null: false
        t.string  :status,      default: 'pending'  # pending|approved|rejected|live
        t.integer :reviewer_user_id
        t.text    :reviewer_note
        t.integer :reward_when_approved, default: 0
        t.timestamps
      end
      add_index :coin_engine_quest_suggestions, :suggester_user_id
      add_index :coin_engine_quest_suggestions, :status
    end

    unless table_exists?(:coin_engine_photo_bounties)
      create_table :coin_engine_photo_bounties do |t|
        t.integer :poster_user_id, null: false
        t.string  :name,       null: false
        t.text    :requirements
        t.integer :reward,     null: false
        t.integer :max_winners, default: 1
        t.integer :awarded_count, default: 0
        t.string  :status,     default: 'active'  # active|expired|completed
        t.datetime :expires_at
        t.timestamps
      end
      add_index :coin_engine_photo_bounties, :poster_user_id
      add_index :coin_engine_photo_bounties, :status
    end
  end

  def down
    drop_table :coin_engine_photo_bounties       if table_exists?(:coin_engine_photo_bounties)
    drop_table :coin_engine_quest_suggestions    if table_exists?(:coin_engine_quest_suggestions)
    drop_table :coin_engine_ama_bookings         if table_exists?(:coin_engine_ama_bookings)
    drop_table :coin_engine_tournament_entries   if table_exists?(:coin_engine_tournament_entries)
    drop_table :coin_engine_tournaments          if table_exists?(:coin_engine_tournaments)
    drop_table :coin_engine_achievements         if table_exists?(:coin_engine_achievements)
  end
end
