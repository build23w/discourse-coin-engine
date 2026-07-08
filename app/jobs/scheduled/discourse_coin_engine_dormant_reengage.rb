# frozen_string_literal: true

module Jobs
  # Re-engagement email for dormant users. "Here's what you missed" digest.
  #
  # v0.34.0 - geo-scoped: dormant users with a profile location get what they
  # missed NEAR THEM (city -> nearby -> province via GeoDigest); skipped if
  # nothing local. Users without a location get the site-wide list.
  class DiscourseCoinEngineDormantReengage < ::Jobs::Scheduled
    every 1.week

    def execute(args)
      return unless SiteSetting.coin_engine_enabled
      return unless SiteSetting.coin_engine_emails_enabled
      return unless SiteSetting.coin_engine_dormant_reengage_enabled

      threshold = SiteSetting.coin_engine_dormant_days_threshold.to_i
      cutoff_recent = threshold.days.ago
      cutoff_floor  = 90.days.ago # don't email truly abandoned accounts

      # Site-wide fallback list
      top_topics = ::Topic.visible
                          .listable_topics
                          .where('topics.created_at >= ? OR topics.bumped_at >= ?', 14.days.ago, 14.days.ago)
                          .order(views: :desc)
                          .limit(5)
                          .pluck(:id, :title, :slug, :views, :posts_count, :like_count)

      geo_cache = {}

      # v0.19.3 - email_digests is on user_options in modern Discourse.
      digest_user_ids = ::UserOption.where(email_digests: true).select(:user_id)
      User.real.activated
          .where(staged: false, suspended_till: nil, silenced_till: nil)
          .where(id: digest_user_ids)
          .where('last_seen_at < ? AND last_seen_at > ?', cutoff_recent, cutoff_floor)
          .find_each(batch_size: 500) do |user|
        begin
          # v0.22.0 - EmailGate kill-switch (Phantom signup bounce-rate fix)
          next unless ::DiscourseCoinEngine::EmailGate.allowed?(user)
          next unless ::DiscourseCoinEngine::EmailThrottle.may_send?(user.id)

          rows = ::DiscourseCoinEngine::GeoDigest.topics_for(
            user, limit: 5, since: 14.days.ago, cache: geo_cache
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

          DiscourseCoinEngineMailer.dormant_reengage(
            user: user, top_topics: rows, geo_label: geo_label
          ).deliver_later
          ::DiscourseCoinEngine::EmailThrottle.mark_sent!(user.id)
        rescue StandardError => e
          Rails.logger.warn "[coin-engine] dormant reengage failed for #{user.username}: #{e.message}"
        end
      end
    end
  end
end
