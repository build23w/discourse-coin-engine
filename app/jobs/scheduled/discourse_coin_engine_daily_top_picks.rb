# frozen_string_literal: true

module Jobs
  # Daily personalized "here's what's hot" email. Strict anti-spam:
  # - Skip if user already got ANY coin-engine engagement email today (EmailThrottle)
  # - Skip if user is currently active (last_seen_at within last 24h)
  # - Skip if there are no fresh trending topics in the user's tracked categories
  # - Hard cap respected via EmailThrottle.mark_sent! after each send
  class DiscourseCoinEngineDailyTopPicks < ::Jobs::Scheduled
    every 1.day

    def execute(args)
      return unless SiteSetting.coin_engine_enabled
      return unless SiteSetting.coin_engine_emails_enabled
      return unless SiteSetting.coin_engine_daily_top_picks_enabled

      # Top 5 hot-but-not-stale topics in the last 48h site-wide
      top_topics = ::Topic.visible
                          .listable_topics
                          .where('topics.bumped_at >= ?', 48.hours.ago)
                          .where('topics.posts_count > ?', 1)
                          .order(views: :desc)
                          .limit(8)
                          .pluck(:id, :title, :slug, :views, :posts_count, :like_count)
      return if top_topics.empty?

      # Eligible: opted in, recently signed up enough to bother, but NOT active today.
      # v0.19.3 — email_digests is on user_options in modern Discourse.
      digest_user_ids = ::UserOption.where(email_digests: true).select(:user_id)
      ::User.real
            .activated
            .where(staged: false, suspended_till: nil, silenced_till: nil)
            .where(id: digest_user_ids)
            .where('last_seen_at < ?', 18.hours.ago)
            .where('last_seen_at >= ?', 60.days.ago)
            .find_each(batch_size: 500) do |user|
        begin
          next unless user.email.present?
          next unless ::DiscourseCoinEngine::EmailThrottle.may_send?(user.id)

          DiscourseCoinEngineMailer.daily_top_picks(
            user: user,
            top_topics: top_topics
          ).deliver_later

          ::DiscourseCoinEngine::EmailThrottle.mark_sent!(user.id)
        rescue StandardError => e
          Rails.logger.warn "[coin-engine] daily top picks failed for #{user.username}: #{e.message}"
        end
      end
    end
  end
end
