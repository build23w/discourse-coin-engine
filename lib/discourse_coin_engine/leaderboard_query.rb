# frozen_string_literal: true

module DiscourseCoinEngine
  # Period-filtered leaderboard query. Reads gamification_scores (per-event/per-day
  # rows where each row's `score` is that day's increment) and aggregates totals.
  class LeaderboardQuery
    def initialize(period:, limit: 25)
      @period = period
      @limit  = limit.to_i.clamp(1, 5000)
    end

    def call
      sql = base_sql(@period)
      ActiveRecord::Base.connection.exec_query(sql, 'coin_engine_leaderboard', binds_for(@period))
        .each_with_index.map do |row, idx|
          {
            rank:     idx + 1,
            user_id:  row['user_id'].to_i,
            username: row['username'],
            name:     row['name'],
            avatar_template: row['uploaded_avatar_id'] ? "/user_avatar/#{Discourse.current_hostname}/#{row['username'].downcase}/{size}/#{row['uploaded_avatar_id']}.png" : "/letter_avatar/#{row['username'].downcase}/{size}/1.png",
            total:    row['total'].to_i
          }
      end
    end

    private

    def base_sql(period)
      filter =
        case period
        when 'week'                       then "AND gs.date >= CURRENT_DATE - INTERVAL '7 days'"
        when 'month'                      then "AND gs.date >= CURRENT_DATE - INTERVAL '30 days'"
        when 'all_excluding_last_week'    then "AND gs.date < CURRENT_DATE - INTERVAL '7 days'"
        else ''
        end

      <<~SQL
        SELECT u.id   AS user_id,
               u.username,
               u.name,
               u.uploaded_avatar_id,
               SUM(gs.score) AS total
        FROM gamification_scores gs
        JOIN users u ON u.id = gs.user_id
        WHERE u.id > 0
          AND u.active = TRUE
          AND u.silenced_till IS NULL
          AND u.suspended_till IS NULL
          #{filter}
        GROUP BY u.id, u.username, u.name, u.uploaded_avatar_id
        HAVING SUM(gs.score) > 0
        ORDER BY total DESC, u.id ASC
        LIMIT #{@limit}
      SQL
    end

    def binds_for(_period)
      []
    end
  end
end
