# frozen_string_literal: true

class DiscourseCoinEngineMailer < ::ActionMailer::Base
  # 2026-06-10 (CE-005): self-register the plugin's app/views so mailer templates
  # resolve. ActionMailer::Base keeps its OWN view_paths; the previous plugin.rb
  # registration ran BEFORE this file was loaded (plugin.rb load-order) and died
  # with NameError every boot, leaving all mailers MissingTemplate. Registering
  # here, inside the class body, removes the ordering dependency entirely.
  prepend_view_path File.expand_path('../../views', __FILE__)

  # 2026-06-10 (CE-014): the dbb518f rebuild fixed template resolution, which
  # exposed the next layer — core's layouts/email_template.html.erb calls
  # email_html_template (EmailHelper) which calls html_lang (ApplicationHelper).
  # Core's UserNotifications gets both via `helper :application, :email`; without
  # them every action died at layout render: ActionView::Template::Error
  # (undefined method 'email_html_template') ×48 @16:01Z.
  helper :application, :email

  # 2026-06-17: give the digest a friendly "From" display name. Previously this
  # was the bare `notification_email`, so mail clients fell back to showing the
  # local-part (the "@ name") of the sender. We now emit `"Display Name" <addr>`.
  # The display name resolves (first non-blank wins):
  #   1. coin_engine_email_sender_name  (admin override, Settings page)
  #   2. the Site Contact Username (site_contact_username, e.g. "BuildersLTD")
  #   3. the site title
  default from: -> { DiscourseCoinEngineMailer.default_from }
  layout 'email_template'

  # Build the RFC-5322 From with a display name. Falls back to the bare address
  # if anything goes wrong so a mailer never dies on a malformed sender.
  def self.default_from
    email = SiteSetting.notification_email
    name  = sender_display_name
    return email if name.blank?

    address = Mail::Address.new(email.to_s)
    address.display_name = name
    address.format
  rescue StandardError
    SiteSetting.notification_email
  end

  # Resolve the sender display name with the documented fallback chain.
  def self.sender_display_name
    override = SiteSetting.coin_engine_email_sender_name.to_s.strip
    return override if override.present?

    username = SiteSetting.site_contact_username.to_s.strip
    if username.present?
      # Use the contact's username (canonical casing via lookup; raw value as
      # a fallback if the user can't be resolved).
      contact = User.find_by(username_lower: username.downcase)
      return (contact&.username.presence || username)
    end

    SiteSetting.title.presence
  rescue StandardError
    nil
  end

  # ===== v0.35.0: click-reward link wrapping =====
  # Wrap a same-site path in a signed tracking/reward link. Views call
  # tracked('/t/slug/123'); campaign + geo context come from ivars set by
  # each mailer action. Falls back to a plain URL on any failure.
  def tracked(dest)
    if SiteSetting.coin_engine_email_click_reward_enabled && @user
      tok = ::DiscourseCoinEngine::EmailToken.generate(
        user_id: @user.id, dest: dest, campaign: @campaign.to_s.presence || 'email', city: @geo_label
      )
      "#{@site_url}/coin-engine/email/visit?tok=#{tok}"
    else
      "#{@site_url}#{dest}"
    end
  rescue StandardError
    "#{@site_url}#{dest}"
  end
  helper_method :tracked

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
    @campaign    = 'streak'
    @coin_name   = SiteSetting.coin_engine_coin_name
    @site_name   = SiteSetting.title
    @site_url    = Discourse.base_url
    @brand_color = SiteSetting.coin_engine_brand_color

    if SiteSetting.coin_engine_streak_freeze_email_cta_enabled
      begin
        tok = ::DiscourseCoinEngine::EmailToken.generate(user_id: user.id, dest: '/', campaign: 'streak', action: 'freeze')
        @freeze_href = "#{@site_url}/coin-engine/email/visit?tok=#{tok}"
        @freeze_cost = SiteSetting.coin_engine_streak_freeze_cost.to_i
      rescue StandardError
        @freeze_href = nil
      end
    end

    mail to: user.email, subject: I18n.t('discourse_coin_engine.streak_warning.subject', days: streak_days)
  end

  def dormant_reengage(user:, top_topics:, geo_label: nil, local_weekly_path: nil)
    @user        = user
    @top_topics  = top_topics
    @geo_label   = geo_label
    @campaign    = 'dormant'
    @local_weekly_path = local_weekly_path
    @coin_name   = SiteSetting.coin_engine_coin_name
    @site_name   = SiteSetting.title
    @site_url    = Discourse.base_url
    @brand_color = SiteSetting.coin_engine_brand_color

    subject = if @geo_label.present?
      "What you missed near #{@geo_label} on #{@site_name}"
    else
      I18n.t('discourse_coin_engine.dormant_reengage.subject', site_name: @site_name)
    end
    mail to: user.email, subject: subject
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

  def manual_payment_receipt(user:, amount:, reason:, payment_id:, issued_by:)
    @user        = user
    @amount      = amount
    @reason      = reason
    @payment_id  = payment_id
    @issued_by   = issued_by
    @coin_name   = SiteSetting.coin_engine_coin_name
    @site_name   = SiteSetting.title
    @site_url    = Discourse.base_url
    @brand_color = SiteSetting.coin_engine_brand_color
    @ledger_url  = "#{@site_url}/t/#{SiteSetting.coin_engine_ledger_topic_id}"

    mail to: user.email,
         subject: I18n.t('discourse_coin_engine.manual_payment.subject', amount: amount, coin: @coin_name, payment_id: payment_id)
  end

  def daily_top_picks(user:, top_topics:, geo_label: nil, local_weekly_path: nil)
    @user        = user
    @top_topics  = top_topics
    @geo_label   = geo_label
    @campaign    = 'daily'
    @local_weekly_path = local_weekly_path
    @coin_name   = SiteSetting.coin_engine_coin_name
    @site_name   = SiteSetting.title
    @site_url    = Discourse.base_url
    @brand_color = SiteSetting.coin_engine_brand_color

    subject = if @geo_label.present?
      "Today near #{@geo_label}: local conversations you'll want in on"
    else
      "Today on #{@site_name}: 5 conversations you'll want in on"
    end
    mail to: user.email, subject: subject
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
