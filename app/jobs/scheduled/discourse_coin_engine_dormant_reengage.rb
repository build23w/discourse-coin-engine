# frozen_string_literal: true

module Jobs
  # Re-engagement email for dormant users. "Here's what you missed" digest.
  class DiscourseCoinEngineDormantReengage < ::Jobs::Scheduled
    every 1.week

    def execute(args)
      return unless SiteSetting.coin_engine_enabled
      return unless SiteSetting.coin_engine_emails_enabled
      return unless SiteSetting.coin_engine_dormant_reengage_enabled

      threshold = SiteSetting.coin_engine_dormant_days_threshold.to_i
      cutoff_recent = threshold.days.ago
      cutoff_floor  = 90.days.ago  # don't email truly abandoned accounts

      top_topics = ::Topic.visible
                          .listable_topics
                          .where('topics.created_at >= ? OR topics.bumped_at >= ?', 14.days.ago, 14.days.ago)
                          .order(views: :desc)
                          .limit(5)
                          .pluck(:id, :title, :slug, :views)

      User.real.activated
          .where(staged: false, suspended_till: nil, silenced_till: nil)
          .where('email_digests = ?', true)
          .where('last_seen_at < ? AND last_seen_at > ?', cutoff_recent, cutoff_floor)
          .find_each(batch_size: 500) do |user|
        begin
          next unless ::DiscourseCoinEngine::EmailThrottle.may_send?(user.id)
          DiscourseCoinEngineMailer.dormant_reengage(user: user, top_topics: top_topics).deliver_later
          ::DiscourseCoinEngine::EmailThrottle.mark_sent!(user.id)
        rescue StandardError => e
          Rails.logger.warn "[coin-engine] dormant reengage failed for #{user.username}: #{e.message}"
        end
      end
    end
  end
end
