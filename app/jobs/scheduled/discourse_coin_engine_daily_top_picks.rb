# frozen_string_literal: true

module Jobs
  # Daily personalized "here's what's hot" email. Strict anti-spam:
  # - Skip if user already got ANY coin-engine engagement email today (EmailThrottle)
  # - Skip if user is currently active (last_seen_at within last 18h)
  # - Hard cap respected via EmailThrottle.mark_sent! after each send
  #
  # v0.34.0 - geo-scoped: users with a profile location get topics from their
  # own city first, then nearby cities, then province (GeoDigest tiers). A
  # located user with NO local content is SKIPPED - we never email off-area
  # topics to someone whose location we know. Users without a location get
  # the site-wide list, unchanged.
  class DiscourseCoinEngineDailyTopPicks < ::Jobs::Scheduled
    every 1.day

    def execute(args)
      return unless SiteSetting.coin_engine_enabled
      return unless SiteSetting.coin_engine_emails_enabled
      return unless SiteSetting.coin_engine_daily_top_picks_enabled

      # Site-wide fallback: top hot-but-not-stale topics of the last 48h
      top_topics = ::Topic.visible
                          .listable_topics
                          .where('topics.bumped_at >= ?', 48.hours.ago)
                          .where('topics.posts_count > ?', 1)
                          .order(views: :desc)
                          .limit(8)
                          .pluck(:id, :title, :slug, :views, :posts_count, :like_count)

      geo_since = SiteSetting.coin_engine_geo_digest_window_days.to_i.clamp(1, 60).days.ago
      geo_cache = {}

      # v0.19.3 - email_digests is on user_options in modern Discourse.
      digest_user_ids = ::UserOption.where(email_digests: true).select(:user_id)
      ::User.real
            .activated
            .where(staged: false, suspended_till: nil, silenced_till: nil)
            .where(id: digest_user_ids)
            .where('last_seen_at < ?', 18.hours.ago)
            .where('last_seen_at >= ?', 60.days.ago)
            .find_each(batch_size: 500) do |user|
        begin
          # v0.22.0 - EmailGate kill-switch (Phantom signup bounce-rate fix)
          next unless ::DiscourseCoinEngine::EmailGate.allowed?(user)
          next unless user.email.present?
          next unless ::DiscourseCoinEngine::EmailThrottle.may_send?(user.id)

          rows = ::DiscourseCoinEngine::GeoDigest.topics_for(
            user, limit: 8, since: geo_since, cache: geo_cache
          )
          geo_label = nil
          if rows.nil?
            rows = top_topics # no location -> site-wide list
          elsif rows.empty?
            next              # located user, nothing local -> skip entirely
          else
            geo_label = ::DiscourseCoinEngine::GeoDigest.label_for(user)
          end
          next if rows.blank?

          DiscourseCoinEngineMailer.daily_top_picks(
            user: user,
            top_topics: rows,
            geo_label: geo_label,
            local_weekly_path: ::DiscourseCoinEngine::GeoDigest.local_weekly_path(user)
          ).deliver_later

          ::DiscourseCoinEngine::EmailThrottle.mark_sent!(user.id)
          ::DiscourseCoinEngine::EmailStats.record_send!(campaign: 'daily', city: geo_label)
        rescue StandardError => e
          Rails.logger.warn "[coin-engine] daily top picks failed for #{user.username}: #{e.message}"
        end
      end
    end
  end
end
