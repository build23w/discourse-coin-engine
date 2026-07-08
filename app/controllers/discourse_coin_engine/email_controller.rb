# frozen_string_literal: true

# v0.35.0 - Signed-link landing for engagement emails. No login required:
# identity comes from the HMAC token, so the click credits the right user
# even when the mail client's browser has no session. Every path ends in a
# same-site redirect - token failures degrade to a plain redirect, never an
# error page in the user's face.
module DiscourseCoinEngine
  class EmailController < ::ApplicationController
    requires_plugin DiscourseCoinEngine::PLUGIN_NAME
    skip_before_action :check_xhr, :preload_json, :redirect_to_login_if_required, :verify_authenticity_token, raise: false

    MAX_TOKEN_AGE_DAYS = 14
    CLICK_FIELD = 'coin_engine_last_email_click_day'

    # GET /coin-engine/email/visit?tok=...
    def visit
      data = ::DiscourseCoinEngine::EmailToken.verify(params[:tok])
      return redirect_to '/', allow_other_host: false if data.nil?

      dest = safe_dest(data[:dest])
      begin
        return redirect_to dest, allow_other_host: false if Date.parse(data[:day].to_s) < MAX_TOKEN_AGE_DAYS.days.ago.to_date
      rescue ArgumentError
        return redirect_to dest, allow_other_host: false
      end

      user = ::User.find_by(id: data[:user_id])
      if user && !user.suspended? && user.active?
        ::DiscourseCoinEngine::EmailStats.record_click!(campaign: data[:campaign], city: data[:city])
        if data[:action] == 'freeze'
          dest = append_param(dest, 'lf-frozen', '1') if apply_streak_freeze(user)
        else
          reward_click(user, data)
        end
      end
      redirect_to dest, allow_other_host: false
    end

    private

    def safe_dest(dest)
      d = dest.to_s
      return '/' unless d.start_with?('/') && !d.start_with?('//') && !d.include?('\\')
      d
    end

    def append_param(dest, k, v)
      "#{dest}#{dest.include?('?') ? '&' : '?'}#{k}=#{v}"
    end

    # Small daily thank-you credit for coming back via a digest link.
    # Hard cap: one reward per user per day (separate from EmailThrottle).
    def reward_click(user, data)
      return unless SiteSetting.coin_engine_email_click_reward_enabled
      amount = SiteSetting.coin_engine_email_click_reward.to_i
      return if amount <= 0

      cf = ::UserCustomField.find_by(user_id: user.id, name: CLICK_FIELD)
      return if cf && cf.value == Date.today.to_s

      ::DiscourseCoinEngine.credit_score(user.id, Date.today, amount)
      ::DiscourseCoinEngine.refresh_user_score(user.id)
      ::DiscourseCoinEngine::EmailStats.record_reward!(campaign: data[:campaign], city: data[:city])
      # Toast only - a PM for a small daily reward would be noise.
      ::DiscourseCoinEngine::Notifier.credit!(
        recipient: user, amount: amount, reason: 'email_click',
        note: 'Welcome back - thanks for opening your digest', send_pm: false
      )

      # user_custom_fields has NO unique index - delete-then-insert.
      ::UserCustomField.where(user_id: user.id, name: CLICK_FIELD).delete_all
      ::UserCustomField.create!(user_id: user.id, name: CLICK_FIELD, value: Date.today.to_s)
    rescue StandardError => e
      Rails.logger.warn("[coin-engine] email click reward failed for user #{user.id}: #{e.message}")
    end

    # One-click streak freeze from the streak-warning email. Same guards as
    # the FAB flow (balance, monthly cap); freezes TODAY. Returns truthy on
    # success so the redirect can carry a confirmation param.
    def apply_streak_freeze(user)
      return false unless SiteSetting.coin_engine_streak_freeze_email_cta_enabled
      cost = SiteSetting.coin_engine_streak_freeze_cost.to_i
      return false if ::DiscourseCoinEngine.coin_user_total(user.id) < cost
      monthly_cap = SiteSetting.coin_engine_streak_freeze_monthly_cap.to_i
      used = ::DiscourseCoinEngine::StreakFreeze.where(user_id: user.id)
                                                .where('freeze_date >= ?', Date.today.beginning_of_month)
                                                .count
      return false if used >= monthly_cap

      ActiveRecord::Base.transaction do
        ::DiscourseCoinEngine.credit_score(user.id, Date.today, -cost)
        ::DiscourseCoinEngine::StreakFreeze.create!(user_id: user.id, freeze_date: Date.today, cost_paid: cost)
        Rails.cache.delete("coin_engine_streak_user_#{user.id}")
      end
      ::DiscourseCoinEngine.refresh_user_score(user.id)
      true
    rescue ActiveRecord::RecordNotUnique
      true # already frozen today - the click still achieved the user's intent
    rescue StandardError => e
      Rails.logger.warn("[coin-engine] email freeze failed for user #{user.id}: #{e.message}")
      false
    end
  end
end
