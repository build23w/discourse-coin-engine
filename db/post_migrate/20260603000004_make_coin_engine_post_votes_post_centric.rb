# frozen_string_literal: true

# v0.29.0 — Make feed voting POST-centric so every post (OP + replies) is
# independently votable (and every author can earn $RENO). Existing topic-level
# votes map cleanly onto the OP post. Uniqueness moves (user_id, topic_id) ->
# (user_id, post_id).
class MakeCoinEnginePostVotesPostCentric < ActiveRecord::Migration[7.0]
  def up
    return unless table_exists?(:coin_engine_post_votes)

    # backfill any missing post_id from the topic's OP
    execute(<<~SQL)
      UPDATE coin_engine_post_votes v
      SET post_id = p.id
      FROM posts p
      WHERE v.post_id IS NULL AND p.topic_id = v.topic_id AND p.post_number = 1
    SQL
    # rows we still can't key to a post are unusable — drop them
    execute("DELETE FROM coin_engine_post_votes WHERE post_id IS NULL")
    # collapse any accidental dupes on (user_id, post_id) keeping the newest
    execute(<<~SQL)
      DELETE FROM coin_engine_post_votes a
      USING coin_engine_post_votes b
      WHERE a.user_id = b.user_id AND a.post_id = b.post_id AND a.id < b.id
    SQL

    if index_exists?(:coin_engine_post_votes, [:user_id, :topic_id], name: 'idx_ce_postvote_uniq')
      remove_index :coin_engine_post_votes, name: 'idx_ce_postvote_uniq'
    end
    unless index_exists?(:coin_engine_post_votes, [:user_id, :post_id], name: 'idx_ce_postvote_post_uniq')
      add_index :coin_engine_post_votes, [:user_id, :post_id], unique: true, name: 'idx_ce_postvote_post_uniq'
    end
    add_index :coin_engine_post_votes, :post_id unless index_exists?(:coin_engine_post_votes, :post_id)
  end

  def down
    # non-destructive
  end
end
