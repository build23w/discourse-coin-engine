# frozen_string_literal: true

module Jobs
  # Re-engagement email for dormant users. "Here's what you missed" digest.
  #
  # v0.34.0 - geo-scoped: dormant users with a profile location get what they
  # missed NEAR THEM (city -> nearby -> province via GeoDigest); skipped if
  # nothing local. Users without a location get the site-wide list.
  #
  # v0.38.0 - staged win-back. The far cutoff was a hardcoded 90 days, which
  # on this site left ~60 eligible accounts out of 3,600. It is now the
  # coin_engine_dormant_days_floor setting, paired with:
  #   * a per-run cap (coin_engine_dormant_daily_cap) - the job runs DAILY now
  #     and works the most recently seen users first, so raising the floor
  #     drains in gentle batches rather than one blast;
  #   * a per-user cooldown (coin_engine_dormant_cooldown_days) tracked in the
  #     custom field coin_engine_dormant_last_sent, so nobody is nagged weekly.
  # With the defaults (90 / 150 / 30) behaviour is the old behaviour minus the
  # weekly repeat - the floor has to be raised deliberately in settings.
  class DiscourseCoinEngineDormantReengage < ::Jobs::Scheduled
    every 1.day

    LAST_SENT_FIELD = 'coin_engine_dormant_last_sent'

    def execute(args)
      return unless SiteSetting.coin_engine_enabled
      return unless SiteSetting.coin_engine_emails_enabled
      return unless SiteSetting.coin_engine_dormant_reengage_enabled

      threshold = SiteSetting.coin_engine_dormant_days_threshold.to_i
      floor     = SiteSetting.coin_engine_dormant_days_floor.to_i
      floor     = threshold + 1 if floor <= threshold
      cap       = SiteSetting.coin_engine_dormant_daily_cap.to_i.clamp(1, 5000)
      cooldown  = SiteSetting.coin_engine_dormant_cooldown_days.to_i.clamp(1, 365)

      cutoff_recent = threshold.days.ago
      cutoff_floor  = floor.days.ago
      cooldown_edge = cooldown.days.ago

      # v0.37.0 - tiered supply: hot -> recent -> evergreen, so a win-back email
      # is never skipped just because the last 14 days were quiet.
      top_topics = ::DiscourseCoinEngine::DigestContent.site_wide(
        limit: 5,
        fresh_hours: 14 * 24,
        recent_days: SiteSetting.coin_engine_digest_recent_days.to_i
      )

      geo_cache = {}
      sent = 0
      scanned = 0

      # v0.19.3 - email_digests is on user_options in modern Discourse.
      digest_user_ids = ::UserOption.where(email_digests: true).select(:user_id)

      # Users already emailed inside the cooldown window are excluded in SQL so a
      # wide floor does not spend the cap re-scanning yesterday's recipients.
      recently_mailed = ::UserCustomField
        .where(name: LAST_SENT_FIELD)
        .where('value >= ?', cooldown_edge.to_date.to_s)
        .select(:user_id)

      # Most recently seen first: the people likeliest to come back get the
      # first batches. find_each would force id order, so pluck ids explicitly.
      ids = User.real.activated
          .where(staged: false, suspended_till: nil, silenced_till: nil)
          .where(id: digest_user_ids)
          .where.not(id: recently_mailed)
          .where('last_seen_at < ? AND last_seen_at > ?', cutoff_recent, cutoff_floor)
          .order(last_seen_at: :desc)
          .limit(cap * 6)
          .pluck(:id)

      ids.each_slice(200) do |slice|
        break if sent >= cap
        User.where(id: slice).sort_by { |u| -u.last_seen_at.to_i }.each do |user|
          break if sent >= cap
          scanned += 1
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
              user: user, top_topics: rows, geo_label: geo_label,
              local_weekly_path: ::DiscourseCoinEngine::GeoDigest.local_weekly_path(user)
            ).deliver_later
            ::DiscourseCoinEngine::EmailThrottle.mark_sent!(user.id)
            mark_dormant_sent!(user.id)
            ::DiscourseCoinEngine::EmailStats.record_send!(campaign: 'dormant', city: geo_label)
            sent += 1
          rescue StandardError => e
            Rails.logger.warn "[coin-engine] dormant reengage failed for #{user.username}: #{e.message}"
          end
        end
      end

      Rails.logger.info "[coin-engine] dormant reengage: sent=#{sent} scanned=#{scanned} eligible=#{ids.size} floor=#{floor}d cap=#{cap} cooldown=#{cooldown}d"
    end

    private

    # user_custom_fields has no unique index: delete-then-insert, never upsert.
    def mark_dormant_sent!(user_id)
      ::UserCustomField.where(user_id: user_id, name: LAST_SENT_FIELD).delete_all
      ::UserCustomField.create!(user_id: user_id, name: LAST_SENT_FIELD, value: Date.today.to_s)
    rescue StandardError => e
      Rails.logger.warn "[coin-engine] dormant last-sent bookkeeping failed for user=#{user_id}: #{e.message}"
    end
  end
end
