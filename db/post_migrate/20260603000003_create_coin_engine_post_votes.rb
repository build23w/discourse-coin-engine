# frozen_string_literal: true

# v0.28.0 — Reddit-style up/down votes on topics (feed posts), wired to the
# $RENO economy. One vote per (user, topic); `rewarded` marks votes that paid
# the author $RENO (used for daily-cap accounting + no double-pay).
class CreateCoinEnginePostVotes < ActiveRecord::Migration[7.0]
  def up
    return if table_exists?(:coin_engine_post_votes)
    create_table :coin_engine_post_votes do |t|
      t.integer  :user_id,        null: false
      t.integer  :topic_id,       null: false
      t.integer  :post_id
      t.integer  :author_user_id
      t.integer  :direction,      null: false, default: 1   # 1 up, -1 down
      t.boolean  :rewarded,       null: false, default: false
      t.timestamps
    end
    add_index :coin_engine_post_votes, [:user_id, :topic_id], unique: true, name: 'idx_ce_postvote_uniq'
    add_index :coin_engine_post_votes, :topic_id
    add_index :coin_engine_post_votes, [:author_user_id, :rewarded]
  end

  def down
    drop_table :coin_engine_post_votes if table_exists?(:coin_engine_post_votes)
  end
end
