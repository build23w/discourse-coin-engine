# frozen_string_literal: true

# name: discourse-coin-engine
# about: Full-stack community-coin gamification engine. Tips, shop, bounties, stakes, squads, mentorships, achievements, tournaments, AMA bookings, DAO votes, verified pros, daily chests, streak freezes, auctions, random airdrops, spotlight rotation, plus the v0.5.x: embeddable tier badges, public showcase profiles, personal insights, themed weeks. Defaults to "$RENO" for home.renovation.reviews; configurable to any community currency.
# version: 0.6.9
# authors: LF Builders
# url: https://github.com/build23w/discourse-coin-engine
# required_version: 3.2.0

enabled_site_setting :coin_engine_enabled

# v0.6.6: a single cache-refresh helper that busts BOTH our coin_engine_score
# serializer cache AND the discourse-gamification leaderboard materialized view.
# Without the materialized-view refresh, the recipient's profile total stays
# stale because Discourse-gamification reads from its cached view, not the
# raw gamification_scores table. Wrapped in best-effort rescue so it never
# blocks a credit even if the gamification plugin's API surface changes.
module ::DiscourseCoinEngine
  def self.refresh_user_score(user_id)
    return unless user_id && user_id.to_i > 0
    begin
      Rails.cache.delete("coin_engine_score_user_#{user_id}")
      Rails.cache.delete("coin_engine_rank_user_#{user_id}")
      Rails.cache.delete("coin_engine_streak_user_#{user_id}")
    rescue StandardError
      nil
    end
    begin
      if defined?(::DiscourseGamification::LeaderboardCachedView)
        ::DiscourseGamification::LeaderboardCachedView.refresh
      end
    rescue StandardError => e
      Rails.logger.warn("[coin_engine] LeaderboardCachedView.refresh failed: #{e.class}: #{e.message}")
    end
  end
end

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
  # v0.6.8: explicitly register our app/views directory so admin_payments index template resolves
  DiscourseCoinEngine::AdminPaymentsController.prepend_view_path(File.expand_path('../app/views', __FILE__)) if defined?(DiscourseCoinEngine::AdminPaymentsController)
  # v0.6.9: Discourse 2026 dropped the server-rendered admin layout. Use no_ember instead.
  DiscourseCoinEngine::AdminPaymentsController.layout 'no_ember' if defined?(DiscourseCoinEngine::AdminPaymentsController)
  load File.expand_path('../app/controllers/discourse_coin_engine/embed_controller.rb', __FILE__)
  load File.expand_path('../app/controllers/discourse_coin_engine/profile_controller.rb', __FILE__)
  load File.expand_path('../app/controllers/discourse_coin_engine/insights_controller.rb', __FILE__)
  load File.expand_path('../app/controllers/discourse_coin_engine/themed_week_controller.rb', __FILE__)
  # v0.6.0 phase controllers
  load File.expand_path('../app/controllers/discourse_coin_engine/economy_controller.rb',    __FILE__)
  load File.expand_path('../app/controllers/discourse_coin_engine/social_controller.rb',     __FILE__)
  load File.expand_path('../app/controllers/discourse_coin_engine/identity_controller.rb',   __FILE__)
  load File.expand_path('../app/controllers/discourse_coin_engine/governance_controller.rb', __FILE__)
  load File.expand_path('../app/controllers/discourse_coin_engine/surprise_controller.rb',   __FILE__)
  # v0.6.0 models
  load File.expand_path('../app/models/discourse_coin_engine/payment.rb', __FILE__)
  load File.expand_path('../app/models/discourse_coin_engine/tip.rb', __FILE__)
  load File.expand_path('../app/models/discourse_coin_engine/shop_item.rb', __FILE__)
  load File.expand_path('../app/models/discourse_coin_engine/bounty.rb', __FILE__)
  load File.expand_path('../app/models/discourse_coin_engine/squad.rb', __FILE__)
  load File.expand_path('../app/models/discourse_coin_engine/achievement.rb', __FILE__)
  load File.expand_path('../app/models/discourse_coin_engine/vote.rb', __FILE__)
  load File.expand_path('../app/models/discourse_coin_engine/daily_chest.rb', __FILE__)

  # v0.4.0: registers the sidebar link AND the modern plugin-show route. We ship
  # a connector at admin/assets/javascripts/discourse/connectors/admin-plugin-config-page-coin-engine/
  # which Ember renders inside the show page. The connector iframes the
  # /admin/plugins/coin-engine/embed URL (same admin payments UI, layoutless)
  # so the existing server-rendered HTML/JS stays as the source of truth.
  # Modern Discourse generates the plugin admin URL from the manifest name,
  # not from the location slug. So the page lives at /admin/plugins/discourse-coin-engine
  # regardless of what we pass here -- our routes below use that prefix to match.
  add_admin_route 'coin_engine.title', 'discourse-coin-engine', use_new_show_route: true

  load File.expand_path('../app/jobs/scheduled/discourse_coin_engine_weekly_digest.rb', __FILE__)
  load File.expand_path('../app/jobs/scheduled/discourse_coin_engine_personal_recap.rb', __FILE__)
  load File.expand_path('../app/jobs/scheduled/discourse_coin_engine_streak_warning.rb', __FILE__)
  load File.expand_path('../app/jobs/scheduled/discourse_coin_engine_dormant_reengage.rb', __FILE__)
  load File.expand_path('../app/jobs/scheduled/discourse_coin_engine_daily_top_picks.rb', __FILE__)
  load File.expand_path('../app/jobs/scheduled/discourse_coin_engine_random_airdrop.rb', __FILE__)
  load File.expand_path('../app/jobs/scheduled/discourse_coin_engine_spotlight_rotation.rb', __FILE__)

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
    # Under /admin/ so Admin::AdminController's session/CSRF/layout assumptions
    # are satisfied, but NOT under /admin/plugins/ (which Discourse's Ember
    # plugin-show route catches first under use_new_show_route: true).
    # Mods bookmark /admin/coin-engine -- that's the full payments UI.
    get  '/admin/coin-engine'                                        => 'discourse_coin_engine/admin_payments#index'
    get  '/admin/coin-engine/embed'                                  => 'discourse_coin_engine/admin_payments#embed'
    get  '/admin/coin-engine/payments.json'                          => 'discourse_coin_engine/admin_payments#list'
    get  '/admin/coin-engine/users/search.json'                      => 'discourse_coin_engine/admin_payments#search_users'
    get  '/admin/coin-engine/users/:id/payments.json'                => 'discourse_coin_engine/admin_payments#user_payments', constraints: { id: %r{\d+} }
    post '/admin/coin-engine/payments.json'                          => 'discourse_coin_engine/admin_payments#create'
    put  '/admin/coin-engine/payments/:id/tx.json'                   => 'discourse_coin_engine/admin_payments#update_tx_signature', constraints: { id: %r{\d+} }

    # Pre-v0.4.5 alias kept alive for any in-flight bookmarks
    get  '/coin-engine/admin'                                        => 'discourse_coin_engine/admin_payments#index'
    get  '/coin-engine/admin/embed'                                  => 'discourse_coin_engine/admin_payments#embed'
    get  '/coin-engine/admin/payments.json'                          => 'discourse_coin_engine/admin_payments#list'
    get  '/coin-engine/admin/users/search.json'                      => 'discourse_coin_engine/admin_payments#search_users'
    get  '/coin-engine/admin/users/:id/payments.json'                => 'discourse_coin_engine/admin_payments#user_payments', constraints: { id: %r{\d+} }
    post '/coin-engine/admin/payments.json'                          => 'discourse_coin_engine/admin_payments#create'
    put  '/coin-engine/admin/payments/:id/tx.json'                   => 'discourse_coin_engine/admin_payments#update_tx_signature', constraints: { id: %r{\d+} }

    # User-facing receipts (used by hrr-ux-pack to inject a "Recent receipts" card on profile pages)
    get  '/coin-engine/user/:username/payments.json'                 => 'discourse_coin_engine/user_recap#payments', constraints: { username: username_re }

    # ===== v0.5.0: Embeddable tier badge (anonymous, iframe/img-friendly) =====
    # /coin-engine/embed/u/:username        -> HTML for iframe drop-in
    # /coin-engine/embed/u/:username.svg    -> SVG for <img> use (markdown, GitHub, etc.)
    # /coin-engine/embed/u/:username.json   -> JSON for SPA consumption
    get  '/coin-engine/embed/u/:username'                            => 'discourse_coin_engine/embed#show', constraints: { username: username_re }, defaults: { format: :html }
    get  '/coin-engine/embed/u/:username.svg'                        => 'discourse_coin_engine/embed#show', constraints: { username: username_re }, defaults: { format: :svg }
    get  '/coin-engine/embed/u/:username.json'                       => 'discourse_coin_engine/embed#show', constraints: { username: username_re }, defaults: { format: :json }

    # ===== v0.5.0: Public profile showcase (SEO-rich, indexable) =====
    get  '/coin-engine/u/:username'                                  => 'discourse_coin_engine/profile#show', constraints: { username: username_re }, defaults: { format: :html }
    get  '/coin-engine/u/:username.json'                             => 'discourse_coin_engine/profile#show', constraints: { username: username_re }, defaults: { format: :json }

    # ===== v0.5.0: Personal insights endpoint =====
    get  '/coin-engine/insights/:username.json'                      => 'discourse_coin_engine/insights#show', constraints: { username: username_re }

    # ===== v0.5.0: Themed week =====
    get  '/coin-engine/themed-week.json'                             => 'discourse_coin_engine/themed_week#show'

    # ===== v0.6.0 Phase 2: Economy (Tips, Shop, Bounties, Stakes) =====
    post '/coin-engine/economy/tips.json'                            => 'discourse_coin_engine/economy#create_tip'
    get  '/coin-engine/economy/tips/sent.json'                       => 'discourse_coin_engine/economy#list_sent_tips'
    get  '/coin-engine/economy/tips/received.json'                   => 'discourse_coin_engine/economy#list_received_tips'
    get  '/coin-engine/economy/shop.json'                            => 'discourse_coin_engine/economy#shop_index'
    post '/coin-engine/economy/shop/:slug/redeem.json'               => 'discourse_coin_engine/economy#redeem_shop_item'
    get  '/coin-engine/economy/redemptions.json'                     => 'discourse_coin_engine/economy#list_redemptions'
    get  '/coin-engine/economy/bounties.json'                        => 'discourse_coin_engine/economy#list_bounties'
    post '/coin-engine/economy/bounties.json'                        => 'discourse_coin_engine/economy#create_bounty'
    post '/coin-engine/economy/bounties/:id/award.json'              => 'discourse_coin_engine/economy#award_bounty', constraints: { id: %r{\d+} }
    get  '/coin-engine/economy/stakes.json'                          => 'discourse_coin_engine/economy#list_stakes'
    post '/coin-engine/economy/stakes.json'                          => 'discourse_coin_engine/economy#create_stake'
    post '/coin-engine/economy/stakes/:id/unstake.json'              => 'discourse_coin_engine/economy#unstake', constraints: { id: %r{\d+} }

    # ===== v0.6.0 Phase 3: Social (Squads, Mentor, Spotlight) =====
    get  '/coin-engine/social/squads.json'                           => 'discourse_coin_engine/social#list_squads'
    get  '/coin-engine/social/squads/:slug.json'                     => 'discourse_coin_engine/social#show_squad'
    post '/coin-engine/social/squads/:slug/join.json'                => 'discourse_coin_engine/social#join_squad'
    post '/coin-engine/social/squads/leave.json'                     => 'discourse_coin_engine/social#leave_squad'
    post '/coin-engine/social/mentorships.json'                      => 'discourse_coin_engine/social#create_mentorship'
    post '/coin-engine/social/mentorships/:id/accept.json'           => 'discourse_coin_engine/social#accept_mentorship', constraints: { id: %r{\d+} }
    get  '/coin-engine/social/spotlights.json'                       => 'discourse_coin_engine/social#list_spotlights'

    # ===== v0.6.0 Phase 4: Identity (Achievements, Tournaments, AMA, Suggestions, Photo Bounties, Wrapped) =====
    get  '/coin-engine/identity/u/:username/achievements.json'       => 'discourse_coin_engine/identity#list_user_achievements', constraints: { username: username_re }
    get  '/coin-engine/identity/tournaments.json'                    => 'discourse_coin_engine/identity#list_tournaments'
    get  '/coin-engine/identity/tournaments/:slug.json'              => 'discourse_coin_engine/identity#show_tournament'
    post '/coin-engine/identity/tournaments/:slug/enter.json'        => 'discourse_coin_engine/identity#enter_tournament'
    post '/coin-engine/identity/tournaments/:slug/vote.json'         => 'discourse_coin_engine/identity#vote_tournament'
    get  '/coin-engine/identity/ama.json'                            => 'discourse_coin_engine/identity#list_ama_bookings'
    post '/coin-engine/identity/ama.json'                            => 'discourse_coin_engine/identity#create_ama_booking'
    get  '/coin-engine/identity/quest_suggestions.json'              => 'discourse_coin_engine/identity#list_quest_suggestions'
    post '/coin-engine/identity/quest_suggestions.json'              => 'discourse_coin_engine/identity#create_quest_suggestion'
    get  '/coin-engine/identity/photo_bounties.json'                 => 'discourse_coin_engine/identity#list_photo_bounties'
    post '/coin-engine/identity/photo_bounties.json'                 => 'discourse_coin_engine/identity#create_photo_bounty'
    get  '/coin-engine/identity/wrapped/:username.json'              => 'discourse_coin_engine/identity#show_wrapped', constraints: { username: username_re }

    # ===== v0.6.0 Phase 5: Governance (Votes, Verified Pro) =====
    get  '/coin-engine/governance/votes.json'                        => 'discourse_coin_engine/governance#list_votes'
    get  '/coin-engine/governance/votes/:slug.json'                  => 'discourse_coin_engine/governance#show_vote'
    post '/coin-engine/governance/votes/:slug/cast.json'             => 'discourse_coin_engine/governance#cast_vote'
    post '/coin-engine/governance/verified_pro/apply.json'           => 'discourse_coin_engine/governance#apply_verified_pro'
    get  '/coin-engine/governance/verified_pro/:username.json'       => 'discourse_coin_engine/governance#verified_pro_lookup', constraints: { username: username_re }
    post '/coin-engine/governance/verified_pro/:user_id/decision.json' => 'discourse_coin_engine/governance#decide_verified_pro', constraints: { user_id: %r{\d+} }

    # ===== v0.6.0 Phase 6: Surprise (Daily Chest, Streak Freeze, Auctions, Airdrops) =====
    post '/coin-engine/surprise/chest/claim.json'                    => 'discourse_coin_engine/surprise#claim_chest'
    post '/coin-engine/surprise/streak_freeze.json'                  => 'discourse_coin_engine/surprise#use_streak_freeze'
    get  '/coin-engine/surprise/auctions.json'                       => 'discourse_coin_engine/surprise#list_auctions'
    get  '/coin-engine/surprise/auctions/:slug.json'                 => 'discourse_coin_engine/surprise#show_auction'
    post '/coin-engine/surprise/auctions/:slug/bid.json'             => 'discourse_coin_engine/surprise#bid_auction'
    get  '/coin-engine/surprise/random_airdrops.json'                => 'discourse_coin_engine/surprise#list_random_airdrops'
  end

  # ===== Serializer enrichment =====
  # Use raw SQL for the gamification table (avoids ::GamificationScore namespace issues).
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

  # v0.5.0 — custom title from coin_engine_custom_titles setting, mapped by score → tier index.
  add_to_serializer(:current_user, :coin_engine_custom_title, include_condition: -> { SiteSetting.coin_engine_enabled }) do
    next nil unless object && object.id && object.id > 0
    begin
      titles = SiteSetting.coin_engine_custom_titles.to_s.split('|').map(&:strip)
      thresholds = SiteSetting.coin_engine_tier_thresholds.to_s.split('|').map(&:to_i)
      next nil if titles.empty? || thresholds.empty?
      score = Rails.cache.fetch("coin_engine_score_user_#{object.id}", expires_in: 5.minutes) do
        ::DiscourseCoinEngine.coin_user_total(object.id)
      end
      idx = thresholds.rindex { |t| score >= t } || 0
      titles[idx]
    rescue StandardError
      nil
    end
  end

  # v0.5.0 — Themed-week summary (site-wide).
  add_to_serializer(:site, :coin_engine_themed_week, include_condition: -> { SiteSetting.coin_engine_enabled }) do
    name = SiteSetting.coin_engine_themed_week_name.to_s
    next nil if name.blank?
    {
      name: name,
      tagline: SiteSetting.coin_engine_themed_week_tagline.to_s,
      hashtag: SiteSetting.coin_engine_themed_week_hashtag.to_s,
      category_id: SiteSetting.coin_engine_themed_week_category_id.to_i,
      multiplier: SiteSetting.coin_engine_themed_week_multiplier.to_f,
      ends_at: SiteSetting.coin_engine_themed_week_ends_at.to_s,
    }
  rescue StandardError
    nil
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

  # ===== v0.6.3 -- surface exceptions from phase controllers as JSON =====
  [
    DiscourseCoinEngine::EconomyController,
    DiscourseCoinEngine::SocialController,
    DiscourseCoinEngine::IdentityController,
    DiscourseCoinEngine::GovernanceController,
    DiscourseCoinEngine::SurpriseController,
    DiscourseCoinEngine::AdminPaymentsController,
    DiscourseCoinEngine::AdminAirdropController,
    DiscourseCoinEngine::EmbedController,
    DiscourseCoinEngine::ProfileController,
    DiscourseCoinEngine::InsightsController,
    DiscourseCoinEngine::ThemedWeekController,
  ].each do |klass|
    klass.class_eval do
      rescue_from StandardError do |e|
        action = (action_name rescue '?')
        Rails.logger.error("[coin_engine] #{self.class.name}##{action} -> #{e.class}: #{e.message}")
        (e.backtrace || []).first(10).each { |frame| Rails.logger.error("  #{frame}") }
        render json: {
          errors: ["#{e.class}: #{e.message}"],
          error_type: 'coin_engine_exception',
          action: action,
          where: (e.backtrace || []).first(3),
        }, status: 500
      end
    end
  end
end
