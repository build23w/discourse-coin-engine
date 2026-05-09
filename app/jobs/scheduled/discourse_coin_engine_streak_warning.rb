# frozen_string_literal: true

module Jobs
  # Daily streak-warning. For each user with a current streak >= min_days who
  # has NOT visited today, send a "don't break your streak" email.
  class DiscourseCoinEngineStreakWarning < ::Jobs::Scheduled
    every 1.day

    def execute(args)
      return unless SiteSetting.coin_engine_enabled
      return unless SiteSetting.coin_engine_emails_enabled
      return unless SiteSetting.coin_engine_streak_warning_enabled

      min_days = SiteSetting.coin_engine_streak_warning_min_days.to_i.clamp(1, 30)

      # Eligibility filter: visited yesterday but not today, last_seen recent enough to bother
      yesterday = Date.today - 1
      candidate_user_ids = ::UserVisit.where(visited_at: yesterday.beginning_of_day..yesterday.end_of_day)
                                      .where.not(user_id: ::UserVisit.where(visited_at: Date.today.beginning_of_day..Date.today.end_of_day).select(:user_id))
                                      .distinct
                                      .pluck(:user_id)

      # v0.19.3 — email_digests is on user_options in modern Discourse.
      digest_user_ids = ::UserOption.where(email_digests: true).select(:user_id)
      User.real.activated
          .where(id: candidate_user_ids, staged: false, suspended_till: nil, silenced_till: nil)
          .where(id: digest_user_ids)
          .find_each(batch_size: 200) do |user|
        begin
          calc = ::DiscourseCoinEngine::StreakCalculator.new(user_id: user.id)
          streak = calc.current
          next if streak < min_days
          DiscourseCoinEngineMailer.streak_warning(user: user, streak_days: streak).deliver_later
        rescue StandardError => e
          Rails.logger.warn "[coin-engine] streak warning failed for #{user.username}: #{e.message}"
        end
      end
    end
  end
end
