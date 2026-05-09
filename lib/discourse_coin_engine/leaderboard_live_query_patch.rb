# frozen_string_literal: true

# v0.19.0 — Leaderboard live-query override.
#
# THE PROBLEM
# -----------
# discourse-gamification's leaderboard reads from a materialized view that has
# to be REFRESHed periodically. We've been running a 1-minute scheduled job
# plus per-user refresh on credit_score, but real-world drift still happens:
# the FAB shows the canonical SUM(gamification_scores.score) live, while the
# leaderboard page shows whatever was cached on the last MV refresh.
#
# Result: a logged-in user sees their FAB say "133,344 $RENO" and the
# leaderboard say "58,743" — same user, two truths, until something forces
# a refresh.
#
# THE FIX
# -------
# Monkey-patch DiscourseGamification::LeaderboardCachedView#scores to compute
# total_score + position from a LIVE GROUP BY on gamification_scores. The MV
# is bypassed entirely. Every leaderboard request runs one indexed aggregate
# query (~ms at hrr scale) and returns fresh numbers.
#
# Caching is per-(leaderboard_id, period, page, for_user_id, limit, offset)
# in Rails.cache for 15 seconds — absorbs concurrent leaderboard page hits
# without re-running the ranking query for each one. 15s is short enough that
# users see their score within a tick or two of crediting, long enough to
# de-amplify load if the page is hammered.
#
# Defense in depth: any unexpected error inside our override falls through to
# the original MV-based implementation, so a bug in the live query never breaks
# the leaderboard.

module ::DiscourseCoinEngine
  module LeaderboardLiveQueryPatch
    CACHE_TTL = 15

    # Period -> SQL date predicate for the WHERE clause on gamification_scores.
    # Mirrors DiscourseGamification::LeaderboardCachedView::PERIOD_INTERVALS but
    # phrased for a direct SQL filter rather than a CTE replacement.
    PERIOD_DATE_FILTERS = {
      'yearly'    => "date >= (CURRENT_DATE - INTERVAL '1 year')",
      'quarterly' => "date >= (CURRENT_DATE - INTERVAL '3 months')",
      'monthly'   => "date >= (CURRENT_DATE - INTERVAL '1 month')",
      'weekly'    => "date >= (CURRENT_DATE - INTERVAL '1 week')",
      'daily'     => "date >= (CURRENT_DATE - INTERVAL '1 day')",
    }.freeze

    def scores(period: 'all_time', page: 0, for_user_id: false, limit: nil, offset: nil)
      coin_engine_live_scores(
        period: period,
        page: page,
        for_user_id: for_user_id,
        limit: limit,
        offset: offset,
      )
    rescue StandardError => e
      Rails.logger.warn("[coin_engine] leaderboard live query failed, falling back to MV: #{e.class}: #{e.message[0,200]}")
      # Defer to the original implementation if the live path fails. The
      # original is aliased below in the Rails.application.config.to_prepare
      # block via super-style chain.
      super
    end

    private

    def coin_engine_live_scores(period:, page:, for_user_id:, limit:, offset:)
      lb_id = leaderboard&.id || 0
      effective_limit  = (limit  || ::DiscourseGamification::GamificationLeaderboard::PAGE_SIZE).to_i
      effective_offset = (offset || 0).to_i
      cache_key = "coin_engine_lb_live_v2:#{lb_id}:#{period}:#{page}:#{for_user_id}:#{effective_limit}:#{effective_offset}"

      Rails.cache.fetch(cache_key, expires_in: CACHE_TTL) do
        run_query(period: period, for_user_id: for_user_id, limit: effective_limit, offset: effective_offset)
      end
    end

    def run_query(period:, for_user_id:, limit:, offset:)
      date_filter = PERIOD_DATE_FILTERS[period.to_s] || nil

      where_clauses = ['1=1']
      where_clauses << date_filter if date_filter

      # Subquery: rank ALL users by their lifetime score, then we filter/page
      # in the outer query. Window function gives us position without a
      # secondary count query. user_id ASC is the tiebreaker so rankings are
      # deterministic across page loads.
      ranking_sql = <<~SQL.strip
        SELECT
          user_id,
          SUM(score)::bigint AS total_score,
          ROW_NUMBER() OVER (ORDER BY SUM(score) DESC, user_id ASC)::int AS position
        FROM gamification_scores
        WHERE #{where_clauses.join(' AND ')}
        GROUP BY user_id
        HAVING SUM(score) > 0
      SQL

      user_filter_sql = for_user_id ? "AND users.id = #{for_user_id.to_i}" : ''

      sql = <<~SQL
        SELECT
          users.id,
          users.name,
          users.username,
          users.uploaded_avatar_id,
          p.total_score,
          p.position
        FROM users
        INNER JOIN (#{ranking_sql}) p ON p.user_id = users.id
        WHERE users.active = TRUE
          AND users.staged = FALSE
          AND users.suspended_at IS NULL
          #{user_filter_sql}
        ORDER BY p.position ASC, users.id ASC
        LIMIT #{limit.to_i} OFFSET #{offset.to_i}
      SQL

      # We return AR-like objects so callers using .id, .username, .total_score,
      # .position all keep working. ActiveRecord::Base#instantiate is the cheap
      # way to get User instances populated with the SELECT'd columns.
      raw = ::ActiveRecord::Base.connection.exec_query(sql)
      raw.to_a.map do |row|
        # Build a User-like struct with the selected attrs. Using a Struct
        # rather than User.new avoids triggering any per-record callbacks
        # the User model might have.
        ::DiscourseCoinEngine::LeaderboardLiveQueryPatch.const_get(:RowStruct).new(
          row['id'],
          row['name'],
          row['username'],
          row['uploaded_avatar_id'],
          row['total_score'],
          row['position'],
        )
      end
    end

    # A lightweight stand-in for User that responds to the methods downstream
    # serializers/callers expect. Keeping it a plain Struct (not a User
    # subclass) because the leaderboard serializer only reads these six fields.
    RowStruct = Struct.new(:id, :name, :username, :uploaded_avatar_id, :total_score, :position) do
      # Some serializers ask for these too — provide harmless defaults.
      def avatar_template
        return nil unless uploaded_avatar_id
        ::User.avatar_template('username', uploaded_avatar_id) rescue nil
      end
      def admin?; false; end
      def moderator?; false; end
      def staff?; false; end
    end
  end
end
