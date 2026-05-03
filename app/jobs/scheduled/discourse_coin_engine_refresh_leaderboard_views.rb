# frozen_string_literal: true

# v0.12.4 - Scheduled MV refresh job. Runs every minute. The Postgres trigger
# (installed by 20260503000007) keeps gamification_leaderboard_scores in
# perfect sync with gamification_scores in real time, but the materialized
# views that /leaderboard/N reads from need an explicit REFRESH to pick up
# the new ledger rows.
#
# CONCURRENTLY mode allows the leaderboard page to keep serving stale data
# during the refresh, then atomically swaps to the new snapshot. Postgres
# requires a unique index on the MV for CONCURRENTLY mode; if the index is
# missing or the MV is empty, falls back to non-concurrent (which briefly
# locks the MV during refresh).

module Jobs
  class DiscourseCoinEngineRefreshLeaderboardViews < ::Jobs::Scheduled
    every 1.minute

    def execute(args)
      return unless SiteSetting.coin_engine_enabled rescue true

      mvs = ::ActiveRecord::Base.connection.execute(
        "SELECT matviewname FROM pg_matviews WHERE matviewname LIKE 'gamification_leaderboard_cache%'"
      ).map { |r| r['matviewname'] }

      return if mvs.empty?

      ok_count = 0
      fail_count = 0
      mvs.each do |mv|
        begin
          ::ActiveRecord::Base.connection.execute("REFRESH MATERIALIZED VIEW CONCURRENTLY #{mv}")
          ok_count += 1
        rescue ::ActiveRecord::StatementInvalid
          # Fallback: no unique index on the MV (or MV not yet populated),
          # so CONCURRENTLY isn't allowed. Use the locking refresh.
          begin
            ::ActiveRecord::Base.connection.execute("REFRESH MATERIALIZED VIEW #{mv}")
            ok_count += 1
          rescue StandardError => e
            fail_count += 1
            Rails.logger.warn("[coin_engine.scheduled.refresh_lb] MV #{mv} non-concurrent fallback failed: #{e.message[0,160]}")
          end
        rescue StandardError => e
          fail_count += 1
          Rails.logger.warn("[coin_engine.scheduled.refresh_lb] MV #{mv} refresh failed: #{e.message[0,160]}")
        end
      end

      # Drop the throttle key so on-demand refresh_leaderboard_views! calls
      # don't no-op due to "ran too recently" — we ARE the periodic refresh now.
      Rails.cache.delete('coin_engine_lb_refresh_at') rescue nil

      Rails.logger.info("[coin_engine.scheduled.refresh_lb] refreshed #{ok_count}/#{mvs.size} MVs (#{fail_count} failed)") if ok_count > 0 || fail_count > 0
    rescue StandardError => e
      Rails.logger.error("[coin_engine.scheduled.refresh_lb] job failed: #{e.class}: #{e.message}")
      # don't re-raise; scheduled jobs should keep running on next tick
    end
  end
end
