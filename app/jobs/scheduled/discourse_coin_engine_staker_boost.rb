# frozen_string_literal: true

module Jobs
  # v0.36.0 - Staker Boost payout. Verified on-chain M3M3 stakers earn a
  # multiplier on EVERYTHING they earned in the forum the previous day
  # (posts, likes, quests, tips-received excluded - see note). Paying the
  # bonus as a next-morning top-up catches every earning source in one
  # place without patching each credit path.
  #
  # Anti-compounding: yesterday's boost amount is recorded and subtracted
  # from yesterday's earnings before computing today's bonus, so the boost
  # never boosts itself.
  class DiscourseCoinEngineStakerBoost < ::Jobs::Scheduled
    every 1.day

    LAST_DAY_FIELD    = 'coin_engine_last_boost_day'
    LAST_AMOUNT_FIELD = 'coin_engine_last_boost_amount'

    def execute(args)
      return unless ::DiscourseCoinEngine::Stake2Earn.enabled?
      return unless SiteSetting.coin_engine_staker_boost_enabled

      mult = SiteSetting.coin_engine_staker_boost_multiplier.to_f
      mult = 1.5 unless mult.between?(1.0, 5.0)
      rate = mult - 1.0
      return if rate <= 0

      cap = SiteSetting.coin_engine_staker_boost_daily_cap.to_i
      yesterday = Date.today - 1

      staker_ids = ::UserCustomField.where(name: ::DiscourseCoinEngine::Stake2Earn::STAKE_FIELD)
                                    .where("value ~ '^[0-9]+$' AND value::bigint > 0")
                                    .pluck(:user_id)
      return if staker_ids.empty?

      staker_ids.each do |user_id|
        begin
          fields = ::UserCustomField.where(user_id: user_id, name: [LAST_DAY_FIELD, LAST_AMOUNT_FIELD])
                                    .pluck(:name, :value).to_h
          next if fields[LAST_DAY_FIELD] == Date.today.to_s # idempotent per day

          earned = day_earnings(user_id, yesterday)
          earned -= fields[LAST_AMOUNT_FIELD].to_i if fields[LAST_DAY_FIELD] == yesterday.to_s
          next if earned <= 0

          bonus = (earned * rate).round
          bonus = [bonus, cap].min if cap > 0
          next if bonus < 1

          ::DiscourseCoinEngine.credit_score(user_id, Date.today, bonus)
          ::DiscourseCoinEngine.refresh_user_score(user_id)

          user = ::User.find_by(id: user_id)
          if user
            # Toast only - a daily PM would be noise.
            ::DiscourseCoinEngine::Notifier.credit!(
              recipient: user, amount: bonus, reason: 'staker_boost',
              note: "#{mult}x Staker Boost on yesterday's earnings", send_pm: false
            )
          end

          ::UserCustomField.where(user_id: user_id, name: [LAST_DAY_FIELD, LAST_AMOUNT_FIELD]).delete_all
          ::UserCustomField.create!(user_id: user_id, name: LAST_DAY_FIELD,    value: Date.today.to_s)
          ::UserCustomField.create!(user_id: user_id, name: LAST_AMOUNT_FIELD, value: bonus.to_s)
        rescue StandardError => e
          Rails.logger.warn "[coin-engine] staker boost failed for #{user_id}: #{e.message}"
        end
      end
    end

    private

    def day_earnings(user_id, date)
      sql = "SELECT COALESCE(SUM(score), 0)::bigint FROM gamification_scores WHERE user_id = $1 AND date = $2"
      r = ActiveRecord::Base.connection.exec_query(sql, 'ce_boost_day_earnings', [user_id, date])
      (r.rows.first&.first || 0).to_i
    rescue StandardError
      0
    end
  end
end
