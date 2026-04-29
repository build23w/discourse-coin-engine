# frozen_string_literal: true

# name: discourse-coin-engine
# about: Configurable community-coin gamification engine. Brandable coin/leaderboard widget pairing, weekly digest emails, streak nudges, dormant re-engagement, on-chain-ready payment ledger. Defaults to "$RENO" for home.renovation.reviews; configurable to any community currency.
# version: 0.2.1
# authors: LF Builders
# url: https://github.com/build23w/discourse-coin-engine
# required_version: 3.2.0

enabled_site_setting :coin_engine_enabled

register_asset 'stylesheets/coin-engine-admin.scss', :admin

after_initialize do
  module ::DiscourseCoinEngine
    PLUGIN_NAME = 'discourse-coin-engine'

    class Engine < ::Rails::Engine
      engine_name PLUGIN_NAME
      isolate_namespace DiscourseCoinEngine
    end
  end

  load File.expand_path('../app/controllers/discourse_coin_engine/config_controller.rb', __FILE__)
  load File.expand_path('../app/controllers/discourse_coin_engine/leaderboard_controller.rb', __FILE__)
  load File.expand_path('../app/controllers/discourse_coin_engine/payments_controller.rb', __FILE__)
  load File.expand_path('../app/controllers/discourse_coin_engine/user_recap_controller.rb', __FILE__)
  load File.expand_path('../app/controllers/discourse_coin_engine/streak_controller.rb', __FILE__)
  load File.expand_path('../app/controllers/discourse_coin_engine/admin_airdrop_controller.rb', __FILE__)

  load File.expand_path('../app/jobs/scheduled/discourse_coin_engine_weekly_digest.rb', __FILE__)
  load File.expand_path('../app/jobs/scheduled/discourse_coin_engine_personal_recap.rb', __FILE__)
  load File.expand_path('../app/jobs/scheduled/discourse_coin_engine_streak_warning.rb', __FILE__)
  load File.expand_path('../app/jobs/scheduled/discourse_coin_engine_dormant_reengage.rb', __FILE__)

  load File.expand_path('../app/mailers/discourse_coin_engine_mailer.rb', __FILE__)

  load File.expand_path('../lib/discourse_coin_engine/leaderboard_query.rb', __FILE__)
  load File.expand_path('../lib/discourse_coin_engine/streak_calculator.rb', __FILE__)
  load File.expand_path('../lib/discourse_coin_engine/ledger_parser.rb', __FILE__)
  load File.expand_path('../lib/discourse_coin_engine/tier_resolver.rb', __FILE__)

  # Username route constraint -- Discourse 2026.x removed User::USERNAME_ROUTE_FORMAT.
  # Inline regex matches the same characters Discourse usernames allow. The
  # controllers also validate via User.find_by so this constraint is defense-in-depth.
  Discourse::Application.routes.append do
    username_re = %r{[\w.\-]+?}
    get  '/coin-engine/config.json'                      => 'discourse_coin_engine/config#show'
    get  '/coin-engine/leaderboard.json'                 => 'discourse_coin_engine/leaderboard#index'
    get  '/coin-engine/payments.json'                    => 'discourse_coin_engine/payments#index'
    get  '/coin-engine/user/:username/recap.json'        => 'discourse_coin_engine/user_recap#show', constraints: { username: username_re }
    get  '/coin-engine/user/:username/streak.json'       => 'discourse_coin_engine/streak#show',     constraints: { username: username_re }
    post '/coin-engine/admin/airdrop.json'               => 'discourse_coin_engine/admin_airdrop#create'
  end

  # ===== Serializer enrichment =====
  # The whole point of this section: make the front-end component zero-fetch.
  # Discourse server-renders `data-preloaded` on every page load; if we enrich
  # the currentUser and topic_list serializers, the component reads everything
  # from that one HTML payload and never needs a second request -- so it's
  # immune to WAF rate-limiting that currently 403s our /leaderboard/1.json
  # and /latest.json XHRs.

  add_to_serializer(:current_user, :coin_engine_score, include_condition: -> { SiteSetting.coin_engine_enabled }) do
    next 0 unless object && object.id && object.id > 0
    begin
      Rails.cache.fetch("coin_engine_score_user_#{object.id}", expires_in: 5.minutes) do
        ::GamificationScore.where(user_id: object.id).sum(:score).to_i
      end
    rescue StandardError
      0
    end
  end

  add_to_serializer(:current_user, :coin_engine_rank, include_condition: -> { SiteSetting.coin_engine_enabled }) do
    next nil unless object && object.id && object.id > 0
    begin
      Rails.cache.fetch("coin_engine_rank_user_#{object.id}", expires_in: 10.minutes) do
        rows = ::DiscourseCoinEngine::LeaderboardQuery.new(period: 'all', limit: 5000).call
        hit = rows.find { |r| r[:user_id] == object.id }
        hit && hit[:rank]
      end
    rescue StandardError
      nil
    end
  end

  add_to_serializer(:current_user, :coin_engine_streak, include_condition: -> { SiteSetting.coin_engine_enabled }) do
    next 0 unless object && object.id && object.id > 0
    begin
      Rails.cache.fetch("coin_engine_streak_user_#{object.id}", expires_in: 1.hour) do
        ::DiscourseCoinEngine::StreakCalculator.new(user_id: object.id).current
      end
    rescue StandardError
      0
    end
  end

  add_to_serializer(:current_user, :coin_engine_tier, include_condition: -> { SiteSetting.coin_engine_enabled }) do
    next nil unless object && object.id && object.id > 0
    begin
      score = Rails.cache.fetch("coin_engine_score_user_#{object.id}", expires_in: 5.minutes) do
        ::GamificationScore.where(user_id: object.id).sum(:score).to_i
      end
      ::DiscourseCoinEngine::TierResolver.new(score).call
    rescue StandardError
      nil
    end
  end

  # Topic-list-item: always expose image_url under a stable plugin field name.
  # Discourse only renders <img> in topic-list rows when `topic_thumbnails` site
  # setting is on; this serializer field gives the component the URL regardless.
  add_to_serializer(:topic_list_item, :coin_engine_image_url, include_condition: -> { SiteSetting.coin_engine_enabled }) do
    object.image_url.presence
  end

  add_to_serializer(:topic_list_item, :coin_engine_views, include_condition: -> { SiteSetting.coin_engine_enabled }) do
    object.views
  end

  if defined?(DiscourseEvent)
    DiscourseEvent.on(:user_promoted) do |args|
      # Reserved for tier-up email trigger when plugin emits coin tier-up events.
    end
  end
end
