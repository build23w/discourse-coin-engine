# frozen_string_literal: true

# v0.18.0 — Rich profile data builder for the gamified public profile.
#
# Single entry point: ProfileBuilder.build(user, viewer: nil)
# Returns a hash that the UserSerializer ships to the browser. The theme
# component reads it from the JSON the SPA fetches at /u/{username}.json
# and renders the social-media-style hero + cards.
#
# Caching: results are cached for 60 seconds keyed on user_id. Profile views
# are read-heavy and the data is mostly slow-changing; we re-derive at most
# once a minute per user. The `viewer:` argument lets us include
# viewer-specific fields (is_self, can_tip, etc.) in the future.
#
# Privacy: only public-readable fields are surfaced. We do NOT include the
# user's email, IP, secret keys, or any moderator-only data. Wallet pubkeys
# are public on-chain so showing them is fine, but we shorten them so
# screenshots don't carry the full address.

module DiscourseCoinEngine
  module ProfileBuilder
    module_function

    CACHE_TTL_SECONDS = 60
    RECENT_POSTS_LIMIT = 10
    BADGES_LIMIT = 12
    TROPHIES_LIMIT = 12
    RECEIPTS_LIMIT = 10

    def build(user, viewer: nil)
      return {} unless user && user.is_a?(::User) && user.id.to_i > 0

      cache_key = "coin_engine_profile_v18:#{user.id}"
      cached = Rails.cache.read(cache_key)
      return cached if cached.is_a?(Hash) && cached[:_cached_at]

      data = build_uncached(user)
      Rails.cache.write(cache_key, data.merge(_cached_at: Time.zone.now.to_i), expires_in: CACHE_TTL_SECONDS)
      data
    rescue StandardError => e
      Rails.logger.warn("[coin_engine.profile] build failed user=#{user&.id}: #{e.class}: #{e.message[0,200]}")
      {}
    end

    # Invalidate the cache for a user — call after credit_score writes,
    # post_created, badge grants, etc., so the next view is fresh.
    def bust!(user_id)
      Rails.cache.delete("coin_engine_profile_v18:#{user_id}") if user_id
    rescue StandardError
    end

    # ---------- builders ----------

    def build_uncached(user)
      {
        score:           coin_score(user),
        rank:            coin_rank(user),
        streak:          coin_streak(user),
        days_visited:    user.user_stat&.days_visited.to_i,
        posts_count:     user.user_stat&.post_count.to_i,
        topics_count:    user.user_stat&.topic_count.to_i,
        likes_received:  user.user_stat&.likes_received.to_i,
        likes_given:     user.user_stat&.likes_given.to_i,
        joined_at:       user.created_at&.iso8601,
        trust_level:     user.trust_level.to_i,
        title:           user.title.to_s.presence,
        location:        location_for(user),
        website:         website_for(user),
        bio_excerpt:     bio_excerpt_for(user),
        wallet:          wallet_for(user),
        recent_posts:    recent_posts_for(user),
        top_badges:      top_badges_for(user),
        top_trophies:    top_trophies_for(user),
        themed_credits:  themed_credit_count_for(user),
        # Verified Pro flag if the plugin tracks it (gracefully nil if not set)
        verified_pro:    verified_pro_for(user),
        # v0.18.1 — public coin receipts (already-public ledger)
        recent_receipts: recent_receipts_for(user),
      }
    end

    def recent_receipts_for(user)
      return [] unless ::ActiveRecord::Base.connection.data_source_exists?('coin_engine_payments')
      rows = ::ActiveRecord::Base.connection.exec_query(
        "SELECT id, amount, reason, source, status, tx_signature, sent_at, created_at " \
        "FROM coin_engine_payments " \
        "WHERE user_id = #{user.id.to_i} AND status IN ('approved','sent','on_chain') " \
        "ORDER BY created_at DESC LIMIT #{RECEIPTS_LIMIT}"
      ).to_a
      rows.map do |r|
        {
          id:            r['id'],
          amount:        r['amount'].to_i,
          reason:        r['reason'].to_s.presence,
          source:        r['source'].to_s,
          status:        r['status'].to_s,
          tx_signature:  r['tx_signature'].to_s.presence,
          sent_at:       r['sent_at']&.iso8601,
          created_at:    r['created_at']&.iso8601,
        }
      end
    rescue StandardError => e
      Rails.logger.warn("[coin_engine.profile] recent_receipts failed: #{e.message[0,160]}")
      []
    end

    # ----- score / rank / streak (mirror what the UserSerializer already exposes when the helper is available) -----

    def coin_score(user)
      if ::DiscourseCoinEngine.respond_to?(:coin_user_total)
        ::DiscourseCoinEngine.coin_user_total(user.id).to_i
      else
        0
      end
    rescue StandardError
      0
    end

    def coin_rank(user)
      # If the leaderboard cache has the user's rank, use it. Otherwise compute
      # cheaply via the gamification_scores table.
      sql = <<~SQL
        SELECT 1 + COUNT(*) FROM (
          SELECT user_id, SUM(score) AS s
          FROM gamification_scores
          GROUP BY user_id
          HAVING SUM(score) > (
            SELECT COALESCE(SUM(score), 0)
            FROM gamification_scores
            WHERE user_id = #{user.id.to_i}
          )
        ) ranked
      SQL
      ::ActiveRecord::Base.connection.select_value(sql).to_i
    rescue StandardError
      0
    end

    def coin_streak(user)
      # Streak is computed from gamification_scores dates. Count the
      # consecutive days ending today (or yesterday) where the user has a row.
      sql = <<~SQL
        SELECT date FROM gamification_scores
        WHERE user_id = #{user.id.to_i}
        ORDER BY date DESC
        LIMIT 60
      SQL
      dates = ::ActiveRecord::Base.connection.select_values(sql).map(&:to_s)
      return 0 if dates.empty?

      streak = 0
      cursor = Date.today
      dates_set = dates.to_set
      # Allow today OR yesterday as the anchor (people post in different timezones)
      cursor = cursor - 1 unless dates_set.include?(cursor.to_s)
      while dates_set.include?(cursor.to_s)
        streak += 1
        cursor -= 1
      end
      streak
    rescue StandardError
      0
    end

    # ----- profile fields -----

    def location_for(user)
      user.user_profile&.location.to_s.strip.presence
    rescue StandardError
      nil
    end

    def website_for(user)
      raw = user.user_profile&.website.to_s.strip
      return nil if raw.empty?
      raw.length > 100 ? "#{raw[0, 97]}..." : raw
    rescue StandardError
      nil
    end

    def bio_excerpt_for(user)
      raw = user.user_profile&.bio_cooked.to_s
      return nil if raw.empty?
      # Strip HTML to plain text, cap length
      text = raw.gsub(/<[^>]+>/, ' ').gsub(/\s+/, ' ').strip
      text.length > 280 ? "#{text[0, 277]}..." : text
    rescue StandardError
      nil
    end

    def wallet_for(user)
      field_id = (SiteSetting.coin_engine_solana_wallet_user_field_id rescue 1).to_i
      raw = ((user.user_fields || {})[field_id.to_s].to_s).strip
      return nil if raw.empty?
      return nil unless raw.match?(/\A[1-9A-HJ-NP-Za-km-z]{32,44}\z/)
      {
        public_key: raw,
        short:      "#{raw[0, 4]}...#{raw[-4, 4]}",
      }
    rescue StandardError
      nil
    end

    # ----- recent posts -----

    def recent_posts_for(user)
      ::Post.where(user_id: user.id, post_type: ::Post.types[:regular], hidden: false, deleted_at: nil)
            .joins(:topic)
            .where(topics: { archetype: ::Archetype.default, deleted_at: nil, visible: true })
            .order(created_at: :desc)
            .limit(RECENT_POSTS_LIMIT)
            .map { |p| serialize_post(p) }
            .compact
    rescue StandardError => e
      Rails.logger.warn("[coin_engine.profile] recent_posts failed: #{e.message[0,160]}")
      []
    end

    def serialize_post(p)
      topic = p.topic
      return nil unless topic
      {
        id:           p.id,
        topic_id:     topic.id,
        topic_title:  topic.title,
        url:          "/t/#{topic.slug}/#{topic.id}/#{p.post_number}",
        excerpt:      ::Post.excerpt(p.cooked, 220, post: p) || '',
        post_number:  p.post_number,
        is_op:        p.post_number == 1,
        like_count:   p.like_count.to_i,
        reply_count:  p.reply_count.to_i,
        category_id:  topic.category_id,
        category_slug: topic.category&.slug,
        category_name: topic.category&.name,
        created_at:   p.created_at&.iso8601,
        word_count:   p.word_count.to_i,
      }
    end

    # ----- badges (Discourse + plugin) -----

    def top_badges_for(user)
      # Discourse badges: enabled, granted, public-show
      rows = ::UserBadge.where(user_id: user.id)
                       .joins(:badge)
                       .where(badges: { enabled: true })
                       .order(granted_at: :desc)
                       .limit(BADGES_LIMIT)
      rows.map { |ub|
        b = ub.badge
        {
          id:          b.id,
          name:        b.display_name,
          description: b.long_description.to_s[0, 160],
          icon:        b.icon.to_s,
          image_url:   b.image_url,
          slug:        b.slug,
          granted_at:  ub.granted_at&.iso8601,
          rarity:      badge_rarity(b),
        }
      }
    rescue StandardError => e
      Rails.logger.warn("[coin_engine.profile] top_badges failed: #{e.message[0,160]}")
      []
    end

    def badge_rarity(badge)
      # Heuristic: lower badge_type_id = rarer. Type 1 = Gold, 2 = Silver, 3 = Bronze.
      case badge.badge_type_id
      when 1 then 'gold'
      when 2 then 'silver'
      else        'bronze'
      end
    rescue StandardError
      'bronze'
    end

    # ----- trophies (custom achievements / quest unlocks) -----

    def top_trophies_for(user)
      # The plugin tracks custom achievements in coin_engine_achievements_unlocked
      # IF that table exists. Gracefully no-op otherwise.
      return [] unless ::ActiveRecord::Base.connection.data_source_exists?('coin_engine_achievements_unlocked')

      rows = ::ActiveRecord::Base.connection.exec_query(
        "SELECT achievement_id, unlocked_at FROM coin_engine_achievements_unlocked " \
        "WHERE user_id = #{user.id.to_i} ORDER BY unlocked_at DESC LIMIT #{TROPHIES_LIMIT}"
      ).to_a
      rows.map do |r|
        {
          id:          r['achievement_id'],
          name:        r['achievement_id'].to_s.tr('_', ' ').capitalize,
          unlocked_at: r['unlocked_at']&.iso8601,
        }
      end
    rescue StandardError => e
      Rails.logger.warn("[coin_engine.profile] top_trophies failed: #{e.message[0,160]}")
      []
    end

    def themed_credit_count_for(user)
      return 0 unless ::ActiveRecord::Base.connection.data_source_exists?('coin_engine_themed_week_credits')
      ::DiscourseCoinEngine::ThemedWeekCredit.where(user_id: user.id).count
    rescue StandardError
      0
    end

    def verified_pro_for(user)
      return nil unless ::ActiveRecord::Base.connection.data_source_exists?('coin_engine_verified_pros')
      row = ::ActiveRecord::Base.connection.exec_query(
        "SELECT company_name, license_state, status FROM coin_engine_verified_pros " \
        "WHERE user_id = #{user.id.to_i} AND status = 'approved' LIMIT 1"
      ).first
      return nil unless row
      {
        company:        row['company_name'],
        license_state:  row['license_state'],
      }
    rescue StandardError
      nil
    end
  end
end
