# frozen_string_literal: true

# Weekly job — picks an underrated post (high quality, low engagement) and spotlights its author.
# Drops bonus $RENO + creates a spotlight record for the public spotlights feed.
module ::Jobs
  class DiscourseCoinEngineSpotlightRotation < ::Jobs::Scheduled
    every 1.week

    def execute(args)
      return unless SiteSetting.coin_engine_enabled
      return unless SiteSetting.coin_engine_spotlight_rotation_enabled rescue false
      reward = (SiteSetting.coin_engine_spotlight_reward rescue 100).to_i
      return if reward <= 0

      # Find a post from the past week that has good quality but low views.
      # Quality proxy: like_count >= 3, posts_read_count <= median.
      sql = <<~SQL
        SELECT p.id AS post_id, p.user_id, p.topic_id, p.like_count
        FROM posts p
        JOIN topics t ON t.id = p.topic_id
        WHERE p.deleted_at IS NULL
          AND t.deleted_at IS NULL
          AND p.created_at > NOW() - INTERVAL '7 days'
          AND p.user_id > 0
          AND p.like_count >= 3
          AND COALESCE(t.views,0) < 100
        ORDER BY (p.like_count * 100 - COALESCE(t.views,0)) DESC NULLS LAST
        LIMIT 1
      SQL
      row = ActiveRecord::Base.connection.exec_query(sql, 'ce_spotlight').rows.first
      return unless row

      post_id, user_id, topic_id = row[0].to_i, row[1].to_i, row[2].to_i
      return unless ::User.where(id: user_id, staged: false, suspended_till: nil).exists?

      ActiveRecord::Base.transaction do
        # v0.12.1 - credit_score helper so leaderboard ledger gets the spotlight reward
        ::DiscourseCoinEngine.credit_score(user_id, Date.today, reward)
        ::DiscourseCoinEngine::Spotlight.create!(
          user_id: user_id, post_id: post_id, topic_id: topic_id,
          reason: 'underrated', reward: reward, featured_at: Time.now
        )
        ::DiscourseCoinEngine.refresh_user_score(user_id)
      end
    rescue StandardError => e
      Rails.logger.warn("[coin_engine] spotlight rotation job: #{e.class} #{e.message}")
    end
  end
end
