# frozen_string_literal: true

# v0.37.0 - Digest content supply.
#
# WHY THIS EXISTS
# Engagement emails were silently mailing nobody. `daily_top_picks` built its
# site-wide list from "bumped in the last 48h AND posts_count > 1". On a forum
# publishing ~13 topics a month that returns an EMPTY set on most days, and the
# caller's `next if rows.blank?` then skipped every recipient. The job ran
# green, Logster stayed clean, and zero mail went out. `dormant_reengage` has
# the same failure with a 14-day window.
#
# The naive fix - "fall back to whatever is recent" - is worse than sending
# nothing: on a quiet week that fills the email with 2-view threads and the
# occasional spam post. So instead of a strict cascade, every candidate is
# scored on real engagement and multiplied by a freshness boost:
#
#     score = (views + 5*likes + 10*replies) * freshness
#     freshness: <fresh_hours 3.0x | <7d 2.0x | <recent_days 1.4x | older 1.0x
#
# Good new content therefore outranks the archive, weak new content doesn't,
# and a site with ~22k topics and a deep archive always has something worth
# opening. Anything under `coin_engine_digest_min_score` is dropped entirely;
# if that leaves nothing, we fall back to top evergreen rather than send empty.
#
# Contract matches GeoDigest.topics_for so mailers and views need no change:
#   => [[id, title, slug, views, posts_count, like_count], ...]
module ::DiscourseCoinEngine
  class DigestContent
    DEFAULT_LIMIT = 8
    # 7th column (bumped_at) is used for scoring then dropped before returning.
    PLUCK   = %i[id title slug views posts_count like_count bumped_at].freeze
    RETURNS = 6

    class << self
      def excluded_category_ids
        SiteSetting.coin_engine_digest_exclude_category_ids.to_s
                   .split('|').map(&:strip).reject(&:empty?).map(&:to_i)
      rescue StandardError
        []
      end

      def min_score
        SiteSetting.coin_engine_digest_min_score.to_i
      rescue StandardError
        40
      end

      def base_scope
        scope = ::Topic.visible.listable_topics.where(archetype: ::Archetype.default)
        ex = excluded_category_ids
        ex.present? ? scope.where.not(category_id: ex) : scope
      end

      def site_wide(limit: DEFAULT_LIMIT, fresh_hours: 48, recent_days: 30, exclude_ids: [])
        limit   = limit.to_i.clamp(1, 25)
        exclude = Array(exclude_ids).map(&:to_i)
        pool    = limit * 5

        fresh = window(recent_days.to_i.days.ago, exclude, pool)
        ever  = window(nil, exclude, pool)

        ranked = (fresh + ever)
                 .uniq { |r| r[0] }
                 .map  { |r| [r, weight(r, fresh_hours, recent_days)] }
                 .select { |(_, w)| w >= min_score }
                 .sort_by { |(_, w)| -w }
                 .map { |(r, _)| r.first(RETURNS) }

        # Never send an empty digest: fall back to the best of the archive.
        ranked = ever.sort_by { |r| -raw_score(r) }.map { |r| r.first(RETURNS) } if ranked.blank?

        ranked.first(limit)
      rescue StandardError => e
        Rails.logger.warn("[coin-engine] DigestContent.site_wide failed: #{e.class}: #{e.message}")
        []
      end

      private

      def window(since, exclude, limit)
        scope = base_scope.where('topics.posts_count > ?', 1)
        scope = scope.where('topics.bumped_at >= ?', since) if since
        scope = scope.where.not(id: exclude) if exclude.present?
        scope.order(Arel.sql('(topics.views + 5 * topics.like_count + 10 * topics.posts_count) DESC'))
             .limit(limit)
             .pluck(*PLUCK)
      end

      def raw_score(row)
        row[3].to_i + 5 * row[5].to_i + 10 * row[4].to_i
      end

      def weight(row, fresh_hours, recent_days)
        bumped = row[6]
        mult =
          if    bumped.nil?                                    then 1.0
          elsif bumped > fresh_hours.to_i.hours.ago            then 3.0
          elsif bumped > 7.days.ago                            then 2.0
          elsif bumped > recent_days.to_i.days.ago             then 1.4
          else                                                      1.0
          end
        (raw_score(row) * mult).round
      end
    end
  end
end
