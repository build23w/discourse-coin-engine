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

      # v0.19.3 — email_digests is on user_options in modern Discourse.
      digest_user_ids = ::UserOption.where(email_digests: true).select(:user_id)
      User.real
          .activated
          .where(staged: false, suspended_till: nil, silenced_till: nil)
          .where(id: digest_user_ids)
          .where('last_seen_at >= ?', 60.days.ago)
          .find_each(batch_size: 500) do |user|
        begin
          next unless user.email.present?
          next unless ::DiscourseCoinEngine::EmailThrottle.may_send?(user.id)

          # v0.19.3 — ::GamificationScore is no longer the canonical class name
          # in current discourse-gamification (it's namespaced or absent on some
          # installs). The previous `rescue 0` silently zeroed every user, so
          # `next if week_score < 10` skipped 100% of recipients. Use raw SQL
          # against gamification_scores like the rest of the plugin does.
          week_score = begin
            sql = "SELECT COALESCE(SUM(score), 0)::int AS total FROM gamification_scores WHERE user_id = $1 AND date >= $2 AND date <= $3"
            r = ::ActiveRecord::Base.connection.exec_query(sql, 'coin_engine_personal_recap_week', [user.id, one_week_ago.to_date, Date.today])
            (r.rows.first && r.rows.first.first || 0).to_i
          rescue StandardError => e
            Rails.logger.warn "[coin-engine] personal recap week_score failed for user_id=#{user.id}: #{e.class}: #{e.message}"
            0
          end
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
          ::DiscourseCoinEngine::EmailThrottle.mark_sent!(user.id)
        rescue StandardError => e
          Rails.logger.warn "[coin-engine] personal recap failed for #{user.username}: #{e.message}"
        end
      end
    end
  end
end
