# frozen_string_literal: true

# v0.34.0 - Geo-scoped digest topic selection.
#
# Picks digest topics for a user based on their profile location, local-first:
#   tier 1: own city          (RrGeo::Util.leveled_tokens weight 1.0)
#   tier 2: nearby cities     (curated map + GeoMesh coordinate radius, 0.7)
#   tier 3: province          (0.45)
#   tier 4: country           (0.2)
# Tiers come from discourse-latest-geo's RrGeo::Util when installed (GeoMesh
# is lat/lon-centroid aware); falls back to comma-segment tokenization if not.
#
# Contract (used by daily_top_picks + dormant_reengage jobs):
#   topics_for(user, ...) => nil   geo doesn't apply (disabled / no location)
#                                  -> caller uses the site-wide list
#                         => []    geo applies but nothing local matched
#                                  -> caller SKIPS the user (isolation: never
#                                     email off-area content to a located user)
#                         => rows  [[id, title, slug, views, posts_count, like_count], ...]
module ::DiscourseCoinEngine
  class GeoDigest
    TOKEN_CAP = 40 # per tier; GeoMesh nearby tiers can get big

    class << self
      def enabled?
        SiteSetting.coin_engine_geo_digest_enabled
      rescue StandardError
        false
      end

      def location_of(user)
        user&.user_profile&.location.to_s.strip
      rescue StandardError
        ''
      end

      # "Toronto, Ontario, Canada" -> "Toronto" (display label for subjects)
      def label_for(user)
        location_of(user).split(',').first.to_s.strip.presence
      end

      # Ordered token tiers, local-first.
      def tiers_for(location)
        return [] if location.blank?
        if defined?(::RrGeo::Util) && ::RrGeo::Util.respond_to?(:leveled_tokens)
          begin
            lv = ::RrGeo::Util.leveled_tokens(location)
            return lv.map { |tokens, _w| Array(tokens) }.reject(&:empty?) if lv.present?
          rescue StandardError
            # fall through to the standalone tokenizer
          end
        end
        fallback_tiers(location)
      end

      # No latest-geo installed: one tier per comma segment, city outward.
      def fallback_tiers(location)
        location.to_s.downcase.split(',').map do |seg|
          words = seg.split(/[^a-z0-9]+/).select { |t| t.length >= 3 }
          next [] if words.empty?
          (words.length > 1 ? [words.join(' ')] : []) + words
        end.reject(&:empty?)
      end

      # Main entry. `cache` is a per-job-run Hash shared across users so all
      # users in the same city cost ONE query set, not N.
      def topics_for(user, limit:, since:, cache: nil)
        return nil unless enabled?
        loc = location_of(user)
        return nil if loc.blank?

        key = "#{loc.downcase}|#{limit}"
        return cache[key] if cache&.key?(key)

        rows = compute(loc, limit: limit, since: since)
        cache[key] = rows if cache
        rows
      rescue StandardError => e
        Rails.logger.warn "[coin-engine] geo digest selection failed: #{e.message}"
        nil
      end

      # Public location-keyed variant (Local Weekly engine, welcome PMs).
      def topics_for_location(location, limit:, since:)
        return [] if location.blank?
        compute(location, limit: limit, since: since)
      rescue StandardError
        []
      end

      # Fresh (<= 8 days) Local Weekly roundup path for the user's city, or nil.
      def local_weekly_path(user)
        city = label_for(user)
        return nil if city.blank?
        rec = ::PluginStore.get('discourse-coin-engine', "local_weekly_#{city.downcase.parameterize}")
        return nil unless rec && rec['topic_id']
        at = (Time.parse(rec['at'].to_s) rescue nil)
        return nil if at.nil? || at < 8.days.ago
        "/t/#{rec['topic_id']}"
      rescue StandardError
        nil
      end

      private

      def compute(location, limit:, since:)
        picked = []
        seen = {}
        tiers_for(location).each do |tokens|
          break if picked.length >= limit
          toks = tokens.map(&:to_s).reject(&:empty?).first(TOKEN_CAP)
          next if toks.empty?
          query_tier(toks, since: since, limit: limit).each do |row|
            next if seen[row[0]]
            seen[row[0]] = true
            picked << row
            break if picked.length >= limit
          end
        end
        picked
      end

      # Topics whose title, category name, or tag matches any tier token.
      # Same matching surface as latest-geo's feed ranker.
      def query_tier(tokens, since:, limit:)
        patterns = tokens.map { |t| "%#{ActiveRecord::Base.sanitize_sql_like(t)}%" }
        title_sql = patterns.map { 'topics.title ILIKE ?' }.join(' OR ')
        cat_sql   = 'topics.category_id IN (SELECT id FROM categories WHERE ' +
                    patterns.map { 'name ILIKE ?' }.join(' OR ') + ')'
        tag_sql   = 'EXISTS (SELECT 1 FROM topic_tags tt JOIN tags tg ON tg.id = tt.tag_id ' \
                    'WHERE tt.topic_id = topics.id AND (' +
                    patterns.map { 'tg.name ILIKE ?' }.join(' OR ') + '))'

        ::Topic.visible
               .listable_topics
               .where('topics.bumped_at >= ?', since)
               .where("(#{title_sql}) OR (#{cat_sql}) OR (#{tag_sql})",
                      *(patterns + patterns + patterns))
               .order(views: :desc)
               .limit(limit)
               .pluck(:id, :title, :slug, :views, :posts_count, :like_count)
      end
    end
  end
end
