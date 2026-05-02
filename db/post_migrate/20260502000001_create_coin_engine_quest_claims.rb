# frozen_string_literal: true

# v0.9.0 — Quest reward claims. One row per (user_id, quest_id) — the unique
# index enforces "claim each quest at most once per user". On INSERT we credit
# gamification_scores; on subsequent attempts the unique conflict short-circuits.
class CreateCoinEngineQuestClaims < ActiveRecord::Migration[7.0]
  def up
    unless table_exists?(:coin_engine_quest_claims)
      create_table :coin_engine_quest_claims do |t|
        t.integer :user_id,     null: false
        t.string  :quest_id,    null: false, limit: 100
        t.integer :xp_granted,   null: false, default: 0
        t.integer :reno_granted, null: false, default: 0
        t.string  :category,    limit: 40    # cached from quest catalog (onboarding, reviewer, etc.)
        t.timestamps
      end
      add_index :coin_engine_quest_claims, [:user_id, :quest_id], unique: true, name: 'idx_ce_quest_claims_user_quest'
      add_index :coin_engine_quest_claims, :user_id, name: 'idx_ce_quest_claims_user'
    end
  end

  def down
    drop_table :coin_engine_quest_claims if table_exists?(:coin_engine_quest_claims)
  end
end
