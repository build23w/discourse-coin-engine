# frozen_string_literal: true

# Personal insights endpoint — powers the "Personal Insights" tab in hrr-ux-pack.
#
# Returns aggregate stats for a user:
#   - top categories they post in (top 5)
#   - posting time-of-day histogram (24 buckets)
#   - posting weekday distribution (7 buckets)
#   - score trajectory (last 12 weeks)
#   - personal bests (longest streak ever, biggest single payment, most-liked post)
#   - streak heatmap data (last 90 days, daily yes/no)
#
# All zero-write, all read-only. Cached per-user for 10 minutes.
module DiscourseCoinEngine
  class InsightsController < ::ApplicationController
    skip_before_action :preload_json
    skip_before_action :check_xhr

    def show
      return render json: { error: 'disabled' }, status: 404 unless SiteSetting.coin_engine_enabled
      user = User.find_by(username_lower: params[:username].to_s.downcase)
      return render json: { error: 'not_found' }, status: 404 unless user

      # Privacy: only the user themselves OR an admin can see their own insights.
      unless current_user && (current_user.id == user.id || current_user.admin?)
        return render json: { error: 'forbidden' }, status: 403
      end

      data = Rails.cache.fetch("coin_engine_insights_#{user.id}", expires_in: 10.minutes) do
        {
          top_categories: top_categories(user.id),
          hour_histogram: hour_histogram(user.id),
          weekday_histogram: weekday_histogram(user.id),
          score_trajectory: score_trajectory(user.id),
          personal_bests: personal_bests(user.id),
          streak_heatmap: streak_heatmap(user.id),
          generated_at: Time.now.utc.iso8601,
        }
      end

      render json: data
    end

    private

    def top_categories(user_id)
      sql = <<~SQL
        SELECT c.id, c.name, c.color, c.slug, COUNT(p.id) AS post_count
        FROM posts p
        JOIN topics t ON t.id = p.topic_id
        JOIN categories c ON c.id = t.category_id
        WHERE p.user_id = $1
          AND p.deleted_at IS NULL
          AND t.deleted_at IS NULL
          AND t.archetype = 'regular'
          AND p.created_at > NOW() - INTERVAL '180 days'
        GROUP BY c.id, c.name, c.color, c.slug
        ORDER BY post_count DESC
        LIMIT 5
      SQL
      ActiveRecord::Base.connection.exec_query(sql, 'coin_engine_top_cats', [user_id]).to_a
    rescue StandardError
      []
    end

    def hour_histogram(user_id)
      sql = <<~SQL
        SELECT EXTRACT(HOUR FROM p.created_at)::int AS hr, COUNT(*) AS n
        FROM posts p
        WHERE p.user_id = $1 AND p.deleted_at IS NULL
          AND p.created_at > NOW() - INTERVAL '90 days'
        GROUP BY hr
        ORDER BY hr
      SQL
      buckets = Array.new(24, 0)
      ActiveRecord::Base.connection.exec_query(sql, 'coin_engine_hour_hist', [user_id]).each do |r|
        buckets[r['hr'].to_i] = r['n'].to_i
      end
      buckets
    rescue StandardError
      Array.new(24, 0)
    end

    def weekday_histogram(user_id)
      sql = <<~SQL
        SELECT EXTRACT(DOW FROM p.created_at)::int AS dow, COUNT(*) AS n
        FROM posts p
        WHERE p.user_id = $1 AND p.deleted_at IS NULL
          AND p.created_at > NOW() - INTERVAL '90 days'
        GROUP BY dow
        ORDER BY dow
      SQL
      buckets = Array.new(7, 0)
      ActiveRecord::Base.connection.exec_query(sql, 'coin_engine_dow_hist', [user_id]).each do |r|
        buckets[r['dow'].to_i] = r['n'].to_i
      end
      buckets
    rescue StandardError
      Array.new(7, 0)
    end

    def score_trajectory(user_id)
      sql = <<~SQL
        SELECT date_trunc('week', date)::date AS wk, SUM(score) AS pts
        FROM gamification_scores
        WHERE user_id = $1
          AND date > NOW() - INTERVAL '12 weeks'
        GROUP BY wk
        ORDER BY wk
      SQL
      ActiveRecord::Base.connection.exec_query(sql, 'coin_engine_traj', [user_id]).to_a
    rescue StandardError
      []
    end

    def personal_bests(user_id)
      bests = {}
      # Most-liked post
      bests[:most_liked_post] = ActiveRecord::Base.connection.exec_query(<<~SQL, 'coin_engine_pb_post', [user_id]).rows.first
        SELECT p.id, p.topic_id, t.title, t.slug, p.like_count, p.created_at
        FROM posts p JOIN topics t ON t.id = p.topic_id
        WHERE p.user_id = $1 AND p.deleted_at IS NULL AND t.deleted_at IS NULL
        ORDER BY p.like_count DESC NULLS LAST LIMIT 1
      SQL
      # Biggest payment
      if defined?(::DiscourseCoinEngine::Payment)
        bests[:biggest_payment] = ::DiscourseCoinEngine::Payment.where(user_id: user_id, status: 'sent')
                                                                 .order(amount: :desc).limit(1)
                                                                 .pluck(:amount, :reason, :sent_at)
                                                                 .first rescue nil
      end
      # Longest streak (use calculator's longest if present)
      bests[:longest_streak] = (::DiscourseCoinEngine::StreakCalculator.new(user_id: user_id).longest rescue nil)
      bests
    rescue StandardError
      {}
    end

    def streak_heatmap(user_id)
      sql = <<~SQL
        SELECT DATE(uv.visited_at) AS d
        FROM user_visits uv
        WHERE uv.user_id = $1
          AND uv.visited_at > NOW() - INTERVAL '90 days'
        GROUP BY DATE(uv.visited_at)
        ORDER BY DATE(uv.visited_at)
      SQL
      visited_dates = ActiveRecord::Base.connection.exec_query(sql, 'coin_engine_heatmap', [user_id]).rows.map { |r| r.first.to_s }
      visited = visited_dates.to_set
      today = Date.today
      90.times.map do |n|
        d = today - (89 - n)
        { date: d.iso8601, active: visited.include?(d.iso8601) }
      end
    rescue StandardError
      []
    end
  end
end
