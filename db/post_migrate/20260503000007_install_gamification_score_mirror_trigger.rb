# frozen_string_literal: true

# v0.12.4 - Postgres trigger that keeps gamification_leaderboard_scores in
# perfect sync with gamification_scores at the database level. Eliminates
# drift between the two ledgers regardless of who is writing.
#
# Why this is needed:
#   - discourse-gamification's ScoreCalculator writes only to gamification_scores
#   - Our credit_score helper writes to both (since v0.9.3)
#   - Other plugins, raw SQL fixes, and future writers may not know about the
#     dual-write convention
#   - Without a database-level guarantee, drift creeps in and users see
#     mismatched balances on /leaderboard/N vs the FAB / profile
#
# How the trigger works:
#   AFTER INSERT OR UPDATE ON gamification_scores FOR EACH ROW:
#     for each active leaderboard:
#       INSERT INTO gamification_leaderboard_scores (...) VALUES (...)
#       ON CONFLICT (leaderboard_id, user_id, date) DO UPDATE SET score = EXCLUDED.score
#
#   AFTER DELETE ON gamification_scores FOR EACH ROW:
#     for each active leaderboard:
#       UPDATE gamification_leaderboard_scores SET score = score - OLD.score
#       WHERE leaderboard_id = lb AND user_id = OLD.user_id AND date = OLD.date
#       (or DELETE if score becomes 0 — we leave it as a 0-row for audit)
#
# Performance:
#   - Each gamification_scores write becomes 1 + N writes (N = active leaderboards)
#   - On this install N=10, so 10x amplification. Acceptable: scoring writes are
#     low-volume (a few per second peak). Postgres handles the loop in the same
#     transaction as the trigger source, so it's atomic.

class InstallGamificationScoreMirrorTrigger < ActiveRecord::Migration[7.0]
  def up
    # Drop any prior version (idempotent re-run)
    execute "DROP TRIGGER IF EXISTS coin_engine_mirror_score_trigger ON gamification_scores"
    execute "DROP FUNCTION IF EXISTS coin_engine_mirror_score_to_leaderboards()"

    execute <<~SQL
      CREATE OR REPLACE FUNCTION coin_engine_mirror_score_to_leaderboards()
      RETURNS TRIGGER
      LANGUAGE plpgsql
      AS $$
      DECLARE
        lb_id INTEGER;
      BEGIN
        IF (TG_OP = 'DELETE') THEN
          FOR lb_id IN SELECT id FROM gamification_leaderboards LOOP
            UPDATE gamification_leaderboard_scores
               SET score = GREATEST(0, score - OLD.score)
             WHERE leaderboard_id = lb_id
               AND user_id = OLD.user_id
               AND date = OLD.date;
          END LOOP;
          RETURN OLD;
        ELSE
          -- INSERT or UPDATE: mirror NEW row to every active leaderboard
          FOR lb_id IN SELECT id FROM gamification_leaderboards LOOP
            INSERT INTO gamification_leaderboard_scores (leaderboard_id, user_id, date, score)
            VALUES (lb_id, NEW.user_id, NEW.date, NEW.score)
            ON CONFLICT (leaderboard_id, user_id, date)
            DO UPDATE SET score = EXCLUDED.score;
          END LOOP;
          RETURN NEW;
        END IF;
      END;
      $$;
    SQL

    execute <<~SQL
      CREATE TRIGGER coin_engine_mirror_score_trigger
      AFTER INSERT OR UPDATE OR DELETE ON gamification_scores
      FOR EACH ROW
      EXECUTE FUNCTION coin_engine_mirror_score_to_leaderboards();
    SQL

    # Also do a one-shot resync of any historical drift, so installations that
    # ran before the trigger existed don't need a separate manual rails-runner.
    say_with_time "[coin_engine] one-shot leaderboard resync (historical drift)" do
      lb_ids = execute("SELECT id FROM gamification_leaderboards").map { |r| r['id'].to_i }
      lb_ids.each do |lb_id|
        execute <<~SQL
          INSERT INTO gamification_leaderboard_scores (leaderboard_id, user_id, date, score)
          SELECT #{lb_id.to_i}, gs.user_id, gs.date, gs.score FROM gamification_scores gs
          ON CONFLICT (leaderboard_id, user_id, date)
          DO UPDATE SET score = EXCLUDED.score
        SQL
      end
      lb_ids.size
    end
  end

  def down
    execute "DROP TRIGGER IF EXISTS coin_engine_mirror_score_trigger ON gamification_scores"
    execute "DROP FUNCTION IF EXISTS coin_engine_mirror_score_to_leaderboards()"
  end
end
