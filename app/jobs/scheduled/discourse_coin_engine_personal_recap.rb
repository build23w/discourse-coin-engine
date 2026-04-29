# frozen_string_literal: true

module Jobs
  # Per-user personal weekly recap. Earnings, rank delta, new badges, current streak.
  class DiscourseCoinEnginePersonalRecap < ::Jobs::Scheduled
    every 1.week

    def execute(args)
      return unless SiteSetting.coin_engine_enabled
      return unless SiteSetting.coin_engine_emails_enabled
      return unless SiteSetting.coin_engine_personal_recap_enabled

      one_week_ago = 7.days.ago

      User.real
          .activated
          .where(staged: false, suspended_till: nil, silenced_till: nil)
          .where('email_digests = ?', true)
          .where('last_seen_at >= ?', 60.days.ago)
          .find_each(batch_size: 500) do |user|
        begin
          next unless user.email.present?

          week_score = ::GamificationScore.where(user_id: user.id, date: one_week_ago.to_date..Date.today).sum(:score) rescue 0
          next if week_score < 10  # don't email users who barely participated

          recent_badges = UserBadge.where(user_id: user.id)
                                   .where('granted_at >= ?', one_week_ago)
                                   .includes(:badge)
                                   .map { |ub| { name: ub.badge.display_name, allow_title: ub.badge.allow_title? } }

          streak = ::DiscourseCoinEngine::StreakCalculator.new(user_id: user.id).current

          DiscourseCoinEngineMailer.personal_recap(
            user: user,
            week_earned: week_score,
            recent_badges: recent_badges,
            streak_days: streak
          ).deliver_later
        rescue StandardError => e
          Rails.logger.warn "[coin-engine] personal recap failed for #{user.username}: #{e.message}"
        end
      end
    end
  end
end
