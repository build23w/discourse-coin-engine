# frozen_string_literal: true

# Public profile showcase page — SEO-rich, indexable, share-friendly.
#
# Goal: each user's profile becomes a real graph node Google will crawl.
# Wires together avatar, tier, top contributions, location (from
# discourse-latest-geo), badges, and a backlink-friendly canonical URL.
#
# Routes:
#   GET /coin-engine/u/:username       -> HTML showcase page
#   GET /coin-engine/u/:username.json  -> JSON for SPA consumption
module DiscourseCoinEngine
  class ProfileController < ::ApplicationController
    skip_before_action :preload_json
    skip_before_action :check_xhr
    skip_before_action :redirect_to_login_if_required, raise: false
    skip_before_action :verify_authenticity_token

    def show
      return render plain: 'Coin engine disabled', status: 404 unless SiteSetting.coin_engine_enabled

      @user = User.find_by(username_lower: params[:username].to_s.downcase)
      return render plain: 'User not found', status: 404 unless @user

      # v0.20.0 — HTML requests redirect to the native Discourse summary page.
      # The native /u/{username}/summary is richly styled by lfProfile (theme
      # component) and serves the same SEO purpose as our showcase HTML did,
      # but without the missing-template breakage that hits when a controller
      # outside the plugin view path tries to render an .erb. JSON responses
      # stay intact for any API consumers.
      if request.format.html?
        return redirect_to "/u/#{@user.username}/summary", allow_other_host: false, status: :see_other
      end

      @username    = @user.username
      @display     = @user.name.presence || @user.username
      @bio         = (@user.user_profile&.bio_excerpt(400, keep_newlines: true) rescue nil).to_s
      @location    = @user.user_profile&.location.to_s
      @website     = @user.user_profile&.website.to_s
      @created_at  = @user.created_at
      @avatar      = UrlHelper.absolute(@user.avatar_template_url.gsub('{size}', '240'))
      @score       = ::DiscourseCoinEngine.coin_user_total(@user.id)
      @tier        = ::DiscourseCoinEngine::TierResolver.new(@score).call rescue nil
      @rank        = lookup_rank(@user.id)
      @streak      = (::DiscourseCoinEngine::StreakCalculator.new(user_id: @user.id).current rescue 0)
      @brand       = SiteSetting.coin_engine_brand_color.presence || '#ff6b35'
      @coin        = SiteSetting.coin_engine_coin_name.presence || '$RENO'
      @site_name   = SiteSetting.title
      @site_host   = Discourse.current_hostname

      @top_topics  = top_topics_for(@user.id)
      @recent_posts = recent_posts_for(@user.id)
      @badges      = top_badges_for(@user.id)
      @custom_title = custom_title_for(@score)

      respond_to do |format|
        format.html { render layout: 'no_ember' }
        format.json do
          render json: {
            username: @username,
            display: @display,
            bio: @bio,
            location: @location,
            score: @score,
            tier: @tier,
            rank: @rank,
            streak: @streak,
            avatar: @avatar,
            top_topics: @top_topics,
            recent_posts: @recent_posts,
            badges: @badges,
            custom_title: @custom_title,
          }
        end
      end
    end

    private

    def lookup_rank(user_id)
      # Canonical shared helper — same filter as the public leaderboard.
      ::DiscourseCoinEngine.rank_for(user_id)
    rescue StandardError
      nil
    end

    # Top topics this user authored, by likes + posts count.
    def top_topics_for(user_id)
      sql = <<~SQL
        SELECT t.id, t.title, t.slug, t.posts_count, t.like_count, t.views, t.created_at
        FROM topics t
        WHERE t.user_id = $1
          AND t.deleted_at IS NULL
          AND t.archetype = 'regular'
          AND t.visible = true
        ORDER BY (COALESCE(t.like_count,0) * 3 + COALESCE(t.posts_count,0)) DESC NULLS LAST
        LIMIT 6
      SQL
      ActiveRecord::Base.connection.exec_query(sql, 'coin_engine_top_topics', [user_id]).to_a
    rescue StandardError
      []
    end

    # Recent posts (excludes the OP if it's the only post in topic).
    def recent_posts_for(user_id)
      sql = <<~SQL
        SELECT p.id, p.topic_id, p.post_number, t.title, t.slug, p.created_at,
               LEFT(p.cooked, 280) AS excerpt
        FROM posts p
        JOIN topics t ON t.id = p.topic_id
        WHERE p.user_id = $1
          AND p.deleted_at IS NULL
          AND t.deleted_at IS NULL
          AND t.archetype = 'regular'
          AND t.visible = true
        ORDER BY p.created_at DESC
        LIMIT 5
      SQL
      ActiveRecord::Base.connection.exec_query(sql, 'coin_engine_recent_posts', [user_id]).to_a
    rescue StandardError
      []
    end

    def top_badges_for(user_id)
      sql = <<~SQL
        SELECT b.name, b.icon, b.image_url, b.description, ub.granted_at
        FROM user_badges ub
        JOIN badges b ON b.id = ub.badge_id
        WHERE ub.user_id = $1 AND b.enabled = true
        ORDER BY b.badge_type_id ASC, ub.granted_at DESC
        LIMIT 8
      SQL
      ActiveRecord::Base.connection.exec_query(sql, 'coin_engine_user_badges', [user_id]).to_a
    rescue StandardError
      []
    end

    # Map score → custom title from coin_engine_custom_titles setting.
    # Setting format: pipe-separated, same length as tier_thresholds.
    def custom_title_for(score)
      titles = SiteSetting.coin_engine_custom_titles.to_s.split('|').map(&:strip)
      thresholds = SiteSetting.coin_engine_tier_thresholds.to_s.split('|').map { |s| s.to_i }
      return nil if titles.empty? || thresholds.empty?
      idx = thresholds.rindex { |t| score >= t } || 0
      titles[idx]
    rescue StandardError
      nil
    end
  end
end
