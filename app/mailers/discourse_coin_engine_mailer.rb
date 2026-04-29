# frozen_string_literal: true

class DiscourseCoinEngineMailer < ::ActionMailer::Base
  default from: -> { SiteSetting.notification_email }
  layout 'email_template'

  def weekly_digest(user:, top:, my_rank:, rank_delta:)
    @user        = user
    @top         = top
    @my_rank     = my_rank
    @rank_delta  = rank_delta
    @coin_name   = SiteSetting.coin_engine_coin_name
    @site_name   = SiteSetting.title
    @site_url    = Discourse.base_url
    @brand_color = SiteSetting.coin_engine_brand_color
    @welcome_url = "#{@site_url}/t/#{SiteSetting.coin_engine_welcome_topic_id}"
    @ledger_url  = "#{@site_url}/t/#{SiteSetting.coin_engine_ledger_topic_id}"

    mail to: user.email, subject: I18n.t('discourse_coin_engine.weekly_digest.subject', site_name: @site_name)
  end

  def personal_recap(user:, week_earned:, recent_badges:, streak_days:)
    @user          = user
    @week_earned   = week_earned
    @recent_badges = recent_badges
    @streak_days   = streak_days
    @coin_name     = SiteSetting.coin_engine_coin_name
    @site_name     = SiteSetting.title
    @site_url      = Discourse.base_url
    @brand_color   = SiteSetting.coin_engine_brand_color

    mail to: user.email, subject: I18n.t('discourse_coin_engine.personal_recap.subject', coin: @coin_name)
  end

  def streak_warning(user:, streak_days:)
    @user        = user
    @streak_days = streak_days
    @coin_name   = SiteSetting.coin_engine_coin_name
    @site_name   = SiteSetting.title
    @site_url    = Discourse.base_url
    @brand_color = SiteSetting.coin_engine_brand_color

    mail to: user.email, subject: I18n.t('discourse_coin_engine.streak_warning.subject', days: streak_days)
  end

  def dormant_reengage(user:, top_topics:)
    @user        = user
    @top_topics  = top_topics
    @coin_name   = SiteSetting.coin_engine_coin_name
    @site_name   = SiteSetting.title
    @site_url    = Discourse.base_url
    @brand_color = SiteSetting.coin_engine_brand_color

    mail to: user.email, subject: I18n.t('discourse_coin_engine.dormant_reengage.subject', site_name: @site_name)
  end

  def airdrop_notification(user:, amount:, reason:)
    @user        = user
    @amount      = amount
    @reason      = reason
    @coin_name   = SiteSetting.coin_engine_coin_name
    @site_name   = SiteSetting.title
    @site_url    = Discourse.base_url
    @brand_color = SiteSetting.coin_engine_brand_color
    @ledger_url  = "#{@site_url}/t/#{SiteSetting.coin_engine_ledger_topic_id}"

    mail to: user.email, subject: I18n.t('discourse_coin_engine.airdrop.subject', amount: amount, coin: @coin_name)
  end

  def tier_up(user:, tier_name:)
    @user        = user
    @tier_name   = tier_name
    @coin_name   = SiteSetting.coin_engine_coin_name
    @site_name   = SiteSetting.title
    @site_url    = Discourse.base_url
    @brand_color = SiteSetting.coin_engine_brand_color

    mail to: user.email, subject: I18n.t('discourse_coin_engine.tier_up.subject', tier: tier_name, site_name: @site_name)
  end
end
