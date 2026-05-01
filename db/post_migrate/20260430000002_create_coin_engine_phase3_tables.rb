# frozen_string_literal: true

# v0.6.0 Phase 3 — Social (Squads, Memberships, Mentorships, Spotlights)
class CreateCoinEnginePhase3Tables < ActiveRecord::Migration[7.0]
  def up
    unless table_exists?(:coin_engine_squads)
      create_table :coin_engine_squads do |t|
        t.string  :slug,        null: false
        t.string  :name,        null: false
        t.string  :region                          # GTA East | GTA West | Hamilton | Ottawa | Custom
        t.string  :icon,        limit: 64
        t.string  :color,       limit: 16
        t.text    :description
        t.integer :member_count, default: 0
        t.integer :total_score,  default: 0
        t.boolean :enabled,     default: true
        t.timestamps
      end
      add_index :coin_engine_squads, :slug, unique: true
      add_index :coin_engine_squads, :region
    end

    unless table_exists?(:coin_engine_squad_memberships)
      create_table :coin_engine_squad_memberships do |t|
        t.integer :squad_id, null: false
        t.integer :user_id,  null: false
        t.string  :role,     default: 'member'  # member|captain
        t.datetime :joined_at, null: false
        t.timestamps
      end
      add_index :coin_engine_squad_memberships, [:squad_id, :user_id], unique: true, name: 'idx_ce_squad_mem_unique'
      add_index :coin_engine_squad_memberships, :user_id
    end

    unless table_exists?(:coin_engine_mentorships)
      create_table :coin_engine_mentorships do |t|
        t.integer :mentor_user_id, null: false
        t.integer :mentee_user_id, null: false
        t.string  :status,         null: false, default: 'pending'  # pending|active|completed|cancelled
        t.datetime :started_at
        t.datetime :ended_at
        t.integer :milestones_hit, default: 0
        t.integer :rewards_paid,   default: 0
        t.text    :note
        t.timestamps
      end
      add_index :coin_engine_mentorships, [:mentor_user_id, :mentee_user_id], unique: true, name: 'idx_ce_mentor_unique'
      add_index :coin_engine_mentorships, :status
    end

    unless table_exists?(:coin_engine_spotlights)
      create_table :coin_engine_spotlights do |t|
        t.integer :user_id,  null: false
        t.integer :post_id
        t.integer :topic_id
        t.string  :reason,   null: false   # underrated|new_member|comeback|admin_pick
        t.integer :reward,   default: 0
        t.datetime :featured_at, null: false
        t.timestamps
      end
      add_index :coin_engine_spotlights, :user_id
      add_index :coin_engine_spotlights, :featured_at
    end
  end

  def down
    drop_table :coin_engine_spotlights         if table_exists?(:coin_engine_spotlights)
    drop_table :coin_engine_mentorships        if table_exists?(:coin_engine_mentorships)
    drop_table :coin_engine_squad_memberships  if table_exists?(:coin_engine_squad_memberships)
    drop_table :coin_engine_squads             if table_exists?(:coin_engine_squads)
  end
end
