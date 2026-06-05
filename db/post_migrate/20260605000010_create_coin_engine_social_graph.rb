# frozen_string_literal: true
# Social layer: one-way follows + reposts ("share to my profile") for shorts and
# topics. The reposts table is the source for the followed-feed; its (kind,ref_id)
# index lets us DISTINCT-ON collapse duplicates so a user who follows several
# people never sees the same shared item twice.
class CreateCoinEngineSocialGraph < ActiveRecord::Migration[7.0]
  def up
    unless table_exists?(:coin_engine_follows)
      create_table :coin_engine_follows do |t|
        t.integer :follower_id,  null: false
        t.integer :following_id, null: false
        t.timestamps
      end
      add_index :coin_engine_follows, [:follower_id, :following_id], unique: true, name: 'idx_ce_follow_uniq'
      add_index :coin_engine_follows, :following_id
    end

    unless table_exists?(:coin_engine_reposts)
      create_table :coin_engine_reposts do |t|
        t.integer :user_id, null: false          # who reposted (the sharer)
        t.string  :kind,    null: false, limit: 16  # 'short' | 'topic'
        t.integer :ref_id,  null: false          # discourse_shorts.id OR topics.id
        t.string  :caption, limit: 280
        t.timestamps
      end
      add_index :coin_engine_reposts, [:user_id, :kind, :ref_id], unique: true, name: 'idx_ce_repost_uniq'
      add_index :coin_engine_reposts, [:kind, :ref_id]
      add_index :coin_engine_reposts, :created_at
      add_index :coin_engine_reposts, [:user_id, :created_at]
    end
  end

  def down
    drop_table :coin_engine_reposts if table_exists?(:coin_engine_reposts)
    drop_table :coin_engine_follows if table_exists?(:coin_engine_follows)
  end
end
