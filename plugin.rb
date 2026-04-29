# frozen_string_literal: true

# name: discourse-coin-engine
# about: Configurable community-coin gamification engine. Brandable coin/leaderboard widget pairing, weekly digest emails, streak nudges, dormant re-engagement, on-chain-ready payment ledger. Defaults to "$RENO" for home.renovation.reviews; configurable to any community currency.
# version: 0.4.0
# authors: LF Builders
# url: https://github.com/build23w/discourse-coin-engine
# required_version: 3.2.0

enabled_site_setting :coin_engine_enabled

# (No registered stylesheets in v0.2.x -- there is no admin UI to style. Re-add
# `register_asset 'stylesheets/coin-engine-admin.scss', :admin` and ship the
# matching file when an admin panel is added.)

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
  load File.expand_path('../app/controllers/discourse_coin_engine/admin_payments_controller.rb', __FILE__)
  load File.expand_path('../app/models/discourse_coin_engine/payment.rb', __FILE__)

  # v0.4.0: registers the sidebar link AND the modern plugin-show route. We ship
  # a connector at admin/assets/javascripts/discourse/connectors/admin-plugin-config-page-coin-engine/
  # which Ember renders inside the show page. The connector iframes the
  # /admin/plugins/coin-engine/embed URL (same admin payments UI, layoutless)
  # so the existing server-rendered HTML/JS stays as the source of truth.
  add_admin_route 'coin_engine.title', 'coin-engine', use_new_show_route: true

  load File.expand_path('../app/jobs/scheduled/discourse_coin_engine_weekly_digest.rb', __FILE__)
  load File.expand_path('../app/jobs/scheduled/discourse_coin_engine_personal_recap.rb', __FILE__)
  load File.expand_path('../app/jobs/scheduled/discourse_coin_engine_streak_warning.rb', __FILE__)
  load File.expand_path('../app/jobs/scheduled/discourse_coin_engine_dormant_reengage.rb', __FILE__)
  load File.expand_path('../app/jobs/scheduled/discourse_coin_engine_daily_top_picks.rb', __FILE__)

  load File.expand_path('../app/mailers/discourse_coin_engine_mailer.rb', __FILE__)

  load File.expand_path('../lib/discourse_coin_engine/leaderboard_query.rb', __FILE__)
  load File.expand_path('../lib/discourse_coin_engine/streak_calculator.rb', __FILE__)
  load File.expand_path('../lib/discourse_coin_engine/ledger_parser.rb', __FILE__)
  load File.expand_path('../lib/discourse_coin_engine/tier_resolver.rb', __FILE__)
  load File.expand_path('../lib/discourse_coin_engine/email_throttle.rb', __FILE__)

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

    # ===== Admin UI for manual payments =====
    # /admin/plugins/coin-engine is the Ember-rendered show page (sidebar link target).
    # /admin/plugins/coin-engine/embed renders the same UI without admin layout
    # so the connector can iframe it inside the show page.
    get  '/admin/plugins/coin-engine/embed'                          => 'discourse_coin_engine/admin_payments#embed'
    get  '/admin/plugins/coin-engine/payments.json'                  => 'discourse_coin_engine/admin_payments#list'
    get  '/admin/plugins/coin-engine/users/search.json'              => 'discourse_coin_engine/admin_payments#search_users'
    get  '/admin/plugins/coin-engine/users/:id/payments.json'        => 'discourse_coin_engine/admin_payments#user_payments', constraints: { id: %r{\d+} }
    post '/admin/plugins/coin-engine/payments.json'                  => 'discourse_coin_engine/admin_payments#create'
    put  '/admin/plugins/coin-engine/payments/:id/tx.json'           => 'discourse_coin_engine/admin_payments#update_tx_signature', constraints: { id: %r{\d+} }

    # User-facing receipts (used by hrr-ux-pack to inject a "Recent receipts" card on profile pages)
    get  '/coin-engine/user/:username/payments.json'                 => 'discourse_coin_engine/user_recap#payments', constraints: { username: username_re }
  end

  # ===== Serializer enrichment =====
  # The whole point of this section: make the front-end component zero-fetch.
  # Discourse server-renders `data-preloaded` on every page load; if we enrich
  # the currentUser and topic_list serializers, the component reads everything
  # from that one HTML payload and never needs a second request -- so it's
  # immune to WAF rate-limiting that currently 403s our /leaderboard/1.json
  # and /latest.json XHRs.

  # Use raw SQL for the gamification table. The plugin's model class is namespaced
  # as `DiscourseGamification::GamificationScore` on some installs; looking up a
  # bare `::GamificationScore` raises NameError. Raw SQL bypasses the constant
  # entirely and returns the real number (the serializer was returning 0 because
  # the rescue was catching that NameError silently).
  ::DiscourseCoinEngine.define_singleton_method(:coin_user_total) do |user_id|
    next 0 unless user_id && user_id > 0
    begin
      sql = "SELECT COALESCE(SUM(score), 0)::int AS total FROM gamification_scores WHERE user_id = $1"
      result = ActiveRecord::Base.connection.exec_query(sql, 'coin_engine_user_total', [user_id])
      (result.rows.first && result.rows.first.first || 0).to_i
    rescue StandardError
      0
    end
  end

  add_to_serializer(:current_user, :coin_engine_score, include_condition: -> { SiteSetting.coin_engine_enabled }) do
    next 0 unless object && object.id && object.id > 0
    Rails.cache.fetch("coin_engine_score_user_#{object.id}", expires_in: 5.minutes) do
      ::DiscourseCoinEngine.coin_user_total(object.id)
    end
  end

  add_to_serializer(:current_user, :coin_engine_rank, include_condition: -> { SiteSetting.coin_engine_enabled }) do
    next nil unless object && object.id && object.id > 0
    Rails.cache.fetch("coin_engine_rank_user_#{object.id}", expires_in: 10.minutes) do
      sql = <<~SQL
        WITH totals AS (
          SELECT user_id, SUM(score) AS total
          FROM gamification_scores
          WHERE user_id > 0
          GROUP BY user_id
        )
        SELECT rank
        FROM (
          SELECT user_id, RANK() OVER (ORDER BY total DESC) AS rank
          FROM totals
        ) ranked
        WHERE user_id = $1
      SQL
      ActiveRecord::Base.connection.exec_query(sql, 'coin_engine_rank', [object.id]).rows.first&.first
    rescue StandardError
      nil
    end
  end

  add_to_serializer(:current_user, :coin_engine_streak, include_condition: -> { SiteSetting.coin_engine_enabled }) do
    next 0 unless object && object.id && object.id > 0
    Rails.cache.fetch("coin_engine_streak_user_#{object.id}", expires_in: 1.hour) do
      ::DiscourseCoinEngine::StreakCalculator.new(user_id: object.id).current
    rescue StandardError
      0
    end
  end

  add_to_serializer(:current_user, :coin_engine_tier, include_condition: -> { SiteSetting.coin_engine_enabled }) do
    next nil unless object && object.id && object.id > 0
    begin
      score = Rails.cache.fetch("coin_engine_score_user_#{object.id}", expires_in: 5.minutes) do
        ::DiscourseCoinEngine.coin_user_total(object.id)
      end
      ::DiscourseCoinEngine::TierResolver.new(score).call
    rescue StandardError
      nil
    end
  end

  add_to_serializer(:topic_list_item, :coin_engine_image_url, include_condition: -> { SiteSetting.coin_engine_enabled }) do
    object.image_url.presence
  end

  add_to_serializer(:topic_list_item, :coin_engine_views, include_condition: -> { SiteSetting.coin_engine_enabled }) do
    object.views
  end

  if defined?(DiscourseEvent)
    DiscourseEvent.on(:user_promoted) do |args|
      # Reserved for tier-up email trigger.
    end
  end
end
