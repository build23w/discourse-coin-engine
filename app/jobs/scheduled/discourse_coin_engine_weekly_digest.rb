# frozen_string_literal: true

module Jobs
  # Weekly leaderboard digest. Sends one email per opted-in user with the top-N
  # leaderboard for the past 7 days plus the recipient's own rank delta.
  class DiscourseCoinEngineWeeklyDigest < ::Jobs::Scheduled
    every 1.week

    def execute(args)
      return unless SiteSetting.coin_engine_enabled
      return unless SiteSetting.coin_engine_emails_enabled
      return unless SiteSetting.coin_engine_weekly_digest_enabled

      top_n = SiteSetting.coin_engine_weekly_digest_top_n.to_i.clamp(3, 25)
      week_top  = ::DiscourseCoinEngine::LeaderboardQuery.new(period: 'week', limit: top_n).call
      this_all  = ::DiscourseCoinEngine::LeaderboardQuery.new(period: 'all', limit: 5000).call
      last_excl = ::DiscourseCoinEngine::LeaderboardQuery.new(period: 'all_excluding_last_week', limit: 5000).call

      this_rank_by_id = this_all.each_with_object({}) { |r, h| h[r[:user_id]] = r[:rank] }
      last_rank_by_id = last_excl.each_with_object({}) { |r, h| h[r[:user_id]] = r[:rank] }

      # v0.19.3 — email_digests lives on user_options in modern Discourse,
      # not users. Subquery against UserOption.
      digest_user_ids = ::UserOption.where(email_digests: true).select(:user_id)
      User.real
          .activated
          .where(staged: false, suspended_till: nil, silenced_till: nil)
          .where(id: digest_user_ids)
          .find_each(batch_size: 500) do |user|
        next unless user.email.present?
        next unless ::DiscourseCoinEngine::EmailThrottle.may_send?(user.id)

        my_rank   = this_rank_by_id[user.id]
        last_rank = last_rank_by_id[user.id]
        rank_delta = (my_rank && last_rank) ? (last_rank - my_rank) : nil

        DiscourseCoinEngineMailer.weekly_digest(
          user: user,
          top: week_top,
          my_rank: my_rank,
          rank_delta: rank_delta
        ).deliver_later
        ::DiscourseCoinEngine::EmailThrottle.mark_sent!(user.id)
      rescue StandardError => e
        Rails.logger.warn "[coin-engine] weekly digest send failed for #{user.username}: #{e.message}"
      end
    end
  end
end
