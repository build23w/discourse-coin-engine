# frozen_string_literal: true

# v0.6.0 Phase 5 — Web3 (DAO votes, Verified Pro flag)
class CreateCoinEnginePhase5Tables < ActiveRecord::Migration[7.0]
  def up
    unless table_exists?(:coin_engine_votes)
      create_table :coin_engine_votes do |t|
        t.string  :slug,       null: false
        t.string  :title,      null: false
        t.text    :description
        t.text    :options,    null: false   # JSON array of {key, label}
        t.datetime :starts_at, null: false
        t.datetime :ends_at,   null: false
        t.string  :status,     default: 'open'   # open|closed|cancelled
        t.string  :weighting,  default: 'one_per_user'  # one_per_user|score_weighted
        t.text    :result_snapshot
        t.integer :created_by_user_id, null: false
        t.timestamps
      end
      add_index :coin_engine_votes, :slug, unique: true
      add_index :coin_engine_votes, :status
      add_index :coin_engine_votes, :ends_at
    end

    unless table_exists?(:coin_engine_vote_ballots)
      create_table :coin_engine_vote_ballots do |t|
        t.integer :vote_id,    null: false
        t.integer :user_id,    null: false
        t.string  :option_key, null: false
        t.integer :weight,     default: 1
        t.timestamps
      end
      add_index :coin_engine_vote_ballots, [:vote_id, :user_id], unique: true, name: 'idx_ce_ballot_unique'
    end

    unless table_exists?(:coin_engine_verified_pros)
      create_table :coin_engine_verified_pros do |t|
        t.integer :user_id,    null: false
        t.string  :company_name
        t.string  :license_number
        t.string  :license_state
        t.string  :verification_status, default: 'pending'  # pending|verified|rejected|revoked
        t.datetime :verified_at
        t.integer :verified_by_user_id
        t.text    :note
        t.timestamps
      end
      add_index :coin_engine_verified_pros, :user_id, unique: true
      add_index :coin_engine_verified_pros, :verification_status
    end
  end

  def down
    drop_table :coin_engine_verified_pros if table_exists?(:coin_engine_verified_pros)
    drop_table :coin_engine_vote_ballots  if table_exists?(:coin_engine_vote_ballots)
    drop_table :coin_engine_votes         if table_exists?(:coin_engine_votes)
  end
end
