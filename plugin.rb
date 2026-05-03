# frozen_string_literal: true

# name: discourse-coin-engine
# about: Full-stack community-coin gamification engine. Tips, shop, bounties, stakes, squads, mentorships, achievements, tournaments, AMA bookings, DAO votes, verified pros, daily chests, streak freezes, auctions, random airdrops, spotlight rotation, plus the v0.5.x: embeddable tier badges, public showcase profiles, personal insights, themed weeks. Defaults to "$RENO" for home.renovation.reviews; configurable to any community currency.
# version: 0.10.5
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
    uid = user_id.to_i
    # Our own caches (5-15min TTL on serializer attrs)
    begin
      Rails.cache.delete("coin_engine_score_user_#{uid}")
      Rails.cache.delete("coin_engine_rank_user_#{uid}")
      Rails.cache.delete("coin_engine_streak_user_#{uid}")
    rescue StandardError
      nil
    end
    # discourse-gamification's internal caches. Different versions key differently;
    # delete every variant we've seen so we work across upgrades.
    begin
      ['gamification_score', 'gamification:score', 'gamification:user', 'gamification_user_score'].each do |prefix|
        Rails.cache.delete("#{prefix}:#{uid}")
        Rails.cache.delete("#{prefix}_#{uid}")
      end
    rescue StandardError
      nil
    end
    # Bust the discourse-gamification leaderboard materialized view.
    # Throttled to once per 60s — REFRESH MATERIALIZED VIEW is a full table scan
    # and we don't want every tip/quest claim to trigger one.
    begin
      ::DiscourseCoinEngine.refresh_leaderboard_views!(throttle: 60)
    rescue StandardError => e
      Rails.logger.warn("[coin_engine] refresh_leaderboard_views! failed: #{e.class}: #{e.message}")
    end
    # Force the user's serializer to repaint by bumping their cache key.
    # `user.refresh_payload` doesn't exist; the canonical bust is touching the user
    # so update_at changes and cache_key invalidates downstream.
    begin
      ::User.where(id: uid).update_all(updated_at: Time.now)
    rescue StandardError
      nil
    end
  end

  # v0.8.5 — bulletproof gamification_scores credit/debit.
  # The previous exec_query/exec_insert calls with raw value bindings silently
  # no-op'd on this Discourse install — Tip records would commit but the
  # gamification_scores INSERT did nothing, so recipients' scores never went up.
  # This version uses safe value interpolation: user_id and amount are integers
  # (.to_i'd here for defense), date is quoted via ActiveRecord. Returns the
  # number of rows affected so callers can verify the credit landed.
  def self.credit_score(user_id, date, amount)
    uid = user_id.to_i
    amt = amount.to_i
    return 0 if uid <= 0 || amt == 0
    quoted_date = ActiveRecord::Base.connection.quote(date)

    # Write 1: gamification_scores (our existing ledger; what coin_engine_score reads).
    sql1 = "INSERT INTO gamification_scores (user_id, date, score) " \
           "VALUES (#{uid}, #{quoted_date}, #{amt}) " \
           "ON CONFLICT (user_id, date) DO UPDATE SET score = gamification_scores.score + EXCLUDED.score"
    result = ActiveRecord::Base.connection.execute(sql1)
    n = result.respond_to?(:cmd_tuples) ? result.cmd_tuples : 1

    # v0.9.3 — Write 2: gamification_leaderboard_scores (discourse-gamification's
    # ledger that powers /leaderboard/N). Without this, our credits never reach
    # the leaderboard UI. Mirror to ALL active leaderboards so per-category /
    # per-period boards stay in sync.
    begin
      if defined?(::DiscourseGamification::GamificationLeaderboard)
        # Pluck IDs once — cheap query, plus we don't load full records.
        lb_ids = ::DiscourseGamification::GamificationLeaderboard.pluck(:id)
        lb_ids.each do |lb_id|
          sql2 = "INSERT INTO gamification_leaderboard_scores (leaderboard_id, user_id, date, score) " \
                 "VALUES (#{lb_id.to_i}, #{uid}, #{quoted_date}, #{amt}) " \
                 "ON CONFLICT (leaderboard_id, user_id, date) DO UPDATE SET score = gamification_leaderboard_scores.score + EXCLUDED.score"
          ActiveRecord::Base.connection.execute(sql2)
        end
      end
    rescue StandardError => e
      Rails.logger.warn("[coin_engine] mirror to gamification_leaderboard_scores failed: #{e.class}: #{e.message}")
    end

    Rails.logger.info("[coin_engine] credit_score user=#{uid} amount=#{amt} rows=#{n}")
    n
  rescue StandardError => e
    Rails.logger.error("[coin_engine] credit_score FAILED user=#{user_id} amount=#{amount}: #{e.class}: #{e.message}")
    raise
  end

  # v0.9.2 — Force-refresh discourse-gamification's materialized leaderboard
  # views. Called from refresh_user_score on every credit, throttled so the
  # full table scan doesn't hammer the DB. Discourse-gamification rebuilds
  # `gamification_leaderboard_user_scores` on a schedule (sometimes daily) so
  # the user's Top-10 / global leaderboard rank lags actual earnings without
  # this nudge. We try the plugin's helper first (cleaner if it exists) and
  # fall back to raw SQL if not.
  def self.refresh_leaderboard_views!(throttle: 60)
    last = Rails.cache.read('coin_engine_lb_refresh_at')
    return if last && Time.now - last < throttle.to_i
    Rails.cache.write('coin_engine_lb_refresh_at', Time.now, expires_in: 1.day)

    refreshed = false
    begin
      if defined?(::DiscourseGamification::LeaderboardCachedView)
        ::DiscourseGamification::LeaderboardCachedView.refresh
        refreshed = true
      end
    rescue StandardError => e
      Rails.logger.warn("[coin_engine] LeaderboardCachedView.refresh: #{e.class}: #{e.message}")
    end

    # Discover the actual MV names. discourse-gamification creates
    # `gamification_leaderboard_cache_{LB_ID}_{PERIOD}` per leaderboard config,
    # so the count is N_leaderboards * 6 periods. We list them at runtime
    # rather than hardcode — works across plugin versions.
    begin
      mvs = ActiveRecord::Base.connection.execute(
        "SELECT matviewname FROM pg_matviews WHERE matviewname LIKE 'gamification_leaderboard_cache%'"
      ).map { |r| r['matviewname'] }
      Rails.logger.info("[coin_engine] discovered #{mvs.size} gamification leaderboard MVs to refresh")
      mvs.each do |mv|
        begin
          ActiveRecord::Base.connection.execute("REFRESH MATERIALIZED VIEW CONCURRENTLY #{mv}")
          refreshed = true
        rescue ActiveRecord::StatementInvalid
          # Retry without CONCURRENTLY (no unique index OR not populated yet)
          begin
            ActiveRecord::Base.connection.execute("REFRESH MATERIALIZED VIEW #{mv}")
            refreshed = true
          rescue StandardError
            nil
          end
        rescue StandardError
          nil
        end
      end
    rescue StandardError => e
      Rails.logger.warn("[coin_engine] MV discovery failed: #{e.class}: #{e.message}")
    end
    refreshed
  end

  def self.coin_user_total_bulk(user_ids)
    return {} unless user_ids.is_a?(Array) && !user_ids.empty?
    ids = user_ids.map(&:to_i).reject { |i| i <= 0 }
    return {} if ids.empty?
    sql = "SELECT user_id, COALESCE(SUM(score), 0)::int AS total FROM gamification_scores WHERE user_id IN (#{ids.join(',')}) GROUP BY user_id"
    ActiveRecord::Base.connection.exec_query(sql, 'coin_user_total_bulk').rows.to_h
  rescue StandardError
    {}
  end

  # v0.8.2: Solana address validation. Solana addresses are base58-encoded
  # ed25519 public keys -> exactly 32 bytes when decoded. Length when base58-
  # encoded falls in 32..44 chars. The base58 alphabet excludes 0/O/I/l to
  # avoid visual confusion. We hand-roll the decoder so we don't depend on
  # a base58 gem.
  BASE58_ALPHABET = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz'.freeze

  def self.base58_decode(str)
    return nil if str.nil? || str.empty?
    num = 0
    str.each_char do |c|
      idx = BASE58_ALPHABET.index(c)
      return nil if idx.nil?
      num = num * 58 + idx
    end
    bytes = []
    while num > 0
      bytes.unshift(num & 0xFF)
      num >>= 8
    end
    # Each leading "1" in base58 represents a leading 0 byte
    str.each_char do |c|
      break unless c == '1'
      bytes.unshift(0)
    end
    bytes.pack('C*')
  rescue StandardError
    nil
  end

  def self.valid_solana_address?(addr)
    return false unless addr.is_a?(String)
    addr = addr.strip
    return false unless addr.match?(/\A[1-9A-HJ-NP-Za-km-z]{32,44}\z/)
    decoded = base58_decode(addr)
    !decoded.nil? && decoded.bytesize == 32
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
  DiscourseCoinEngine::AdminPaymentsController.layout false if defined?(DiscourseCoinEngine::AdminPaymentsController)
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
  # v0.8.4: public transparency ledger
  load File.expand_path('../app/controllers/discourse_coin_engine/public_ledger_controller.rb', __FILE__)
  # v0.9.0: server-verified quest reward claims
  load File.expand_path('../app/controllers/discourse_coin_engine/quests_controller.rb', __FILE__)
  # v0.9.1: on-demand fresh score endpoint (gamification_score = coin_engine_score, same SUM)
  load File.expand_path('../app/controllers/discourse_coin_engine/me_controller.rb', __FILE__)
  # v0.6.0 models
  load File.expand_path('../app/models/discourse_coin_engine/payment.rb', __FILE__)
  load File.expand_path('../app/models/discourse_coin_engine/tip.rb', __FILE__)
  load File.expand_path('../app/models/discourse_coin_engine/shop_item.rb', __FILE__)
  load File.expand_path('../app/models/discourse_coin_engine/bounty.rb', __FILE__)
  # v0.10.0 — random_reach bounty support
  load File.expand_path('../app/models/discourse_coin_engine/bounty_invitation.rb', __FILE__)
  load File.expand_path('../app/models/discourse_coin_engine/bounty_claim.rb', __FILE__)
  load File.expand_path('../app/models/discourse_coin_engine/squad.rb', __FILE__)
  load File.expand_path('../app/models/discourse_coin_engine/achievement.rb', __FILE__)
  load File.expand_path('../app/models/discourse_coin_engine/vote.rb', __FILE__)
  load File.expand_path('../app/models/discourse_coin_engine/daily_chest.rb', __FILE__)
  # v0.9.0: server-verified quest reward claims
  load File.expand_path('../app/models/discourse_coin_engine/quest_claim.rb', __FILE__)

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
  # v0.8.4: cross-feature credit notifier (PM + MessageBus push)
  load File.expand_path('../lib/discourse_coin_engine/notifier.rb', __FILE__)
  # v0.9.0: server-side quest validator (mirrors client catalog, enforces threshold)
  load File.expand_path('../lib/discourse_coin_engine/quest_validator.rb', __FILE__)
  # v0.10.0: random_reach bounty dispatcher
  load File.expand_path('../lib/discourse_coin_engine/bounty_dispatcher.rb', __FILE__)
  load File.expand_path('../app/jobs/regular/expire_bounty_round.rb', __FILE__)
  # v0.10.1: Verified Pro admin queue + on-approval cascade
  load File.expand_path('../app/controllers/discourse_coin_engine/admin_verified_pros_controller.rb', __FILE__)
  DiscourseCoinEngine::AdminVerifiedProsController.layout false if defined?(DiscourseCoinEngine::AdminVerifiedProsController)

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

    # v0.7.0: stats banner + paginated all-user browser
    get  '/admin/coin-engine/stats.json'                             => 'discourse_coin_engine/admin_payments#stats'
    get  '/admin/coin-engine/users.json'                             => 'discourse_coin_engine/admin_payments#list_all_users'

    # v0.10.1: Verified Pro admin queue
    get  '/admin/coin-engine/verified_pros.json'                     => 'discourse_coin_engine/admin_verified_pros#index'
    get  '/admin/coin-engine/verified_pros/stats.json'               => 'discourse_coin_engine/admin_verified_pros#stats'
    post '/admin/coin-engine/verified_pros/:user_id/decide.json'        => 'discourse_coin_engine/admin_verified_pros#decide',       constraints: { user_id: %r{\d+} }
    post '/admin/coin-engine/verified_pros/:user_id/request_info.json'  => 'discourse_coin_engine/admin_verified_pros#request_info', constraints: { user_id: %r{\d+} }

    # Pre-v0.4.5 alias kept alive for any in-flight bookmarks
    get  '/coin-engine/admin'                                        => 'discourse_coin_engine/admin_payments#index'
    get  '/coin-engine/admin/embed'                                  => 'discourse_coin_engine/admin_payments#embed'
    get  '/coin-engine/admin/payments.json'                          => 'discourse_coin_engine/admin_payments#list'
    get  '/coin-engine/admin/users/search.json'                      => 'discourse_coin_engine/admin_payments#search_users'
    get  '/coin-engine/admin/users/:id/payments.json'                => 'discourse_coin_engine/admin_payments#user_payments', constraints: { id: %r{\d+} }
    post '/coin-engine/admin/payments.json'                          => 'discourse_coin_engine/admin_payments#create'
    put  '/coin-engine/admin/payments/:id/tx.json'                   => 'discourse_coin_engine/admin_payments#update_tx_signature', constraints: { id: %r{\d+} }

    # v0.7.0 legacy alias
    get  '/coin-engine/admin/stats.json'                             => 'discourse_coin_engine/admin_payments#stats'
    get  '/coin-engine/admin/users.json'                             => 'discourse_coin_engine/admin_payments#list_all_users'

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
    post '/coin-engine/economy/bounties/:id/claim.json'              => 'discourse_coin_engine/economy#claim_bounty', constraints: { id: %r{\d+} }
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

    # ===== v0.8.4 Public transparency ledger =====
    # Combined feed + per-event-type endpoints. Anonymous (no auth required).
    get  '/coin-engine/ledger/recent.json'                           => 'discourse_coin_engine/public_ledger#recent'
    get  '/coin-engine/ledger/tips.json'                             => 'discourse_coin_engine/public_ledger#tips'
    get  '/coin-engine/ledger/bounties.json'                         => 'discourse_coin_engine/public_ledger#bounties'
    get  '/coin-engine/ledger/votes.json'                            => 'discourse_coin_engine/public_ledger#votes'
    get  '/coin-engine/ledger/redemptions.json'                      => 'discourse_coin_engine/public_ledger#redemptions'
    get  '/coin-engine/ledger/payments.json'                         => 'discourse_coin_engine/public_ledger#payments'

    # ===== v0.9.0 Quest reward claims =====
    post '/coin-engine/quests/claim_batch.json'                      => 'discourse_coin_engine/quests#claim_batch'
    get  '/coin-engine/quests/claims.json'                           => 'discourse_coin_engine/quests#list_claims'

    # ===== v0.9.1 On-demand fresh score (busts caches, no stale read) =====
    get  '/coin-engine/me/score.json'                                => 'discourse_coin_engine/me#score'
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

  # v0.10.1 — Surface Verified Pro status on user cards / posts so themes can pin a pill.
  add_to_serializer(:user_card, :coin_engine_verified_pro, include_condition: -> { SiteSetting.coin_engine_enabled }) do
    next nil unless object && object.id
    Rails.cache.fetch("coin_engine_vp_#{object.id}", expires_in: 10.minutes) do
      vp = ::DiscourseCoinEngine::VerifiedPro.find_by(user_id: object.id)
      next nil unless vp && vp.verification_status == 'verified'
      { verified: true, company: vp.company_name, since: vp.verified_at }
    end
  rescue StandardError
    nil
  end

  add_to_serializer(:topic_list_item, :coin_engine_views, include_condition: -> { SiteSetting.coin_engine_enabled }) do
    object.views
  end

  if defined?(DiscourseEvent)
    DiscourseEvent.on(:user_promoted) do |args|
      # Reserved for tier-up email trigger.
    end

    # v0.10.0 — auto-claim random_reach bounties when an invited user replies
    # on the bounty's topic. We check for any open random_reach bounty matching
    # the topic + user pair and run BountyDispatcher.attempt_claim! atomically.
    DiscourseEvent.on(:post_created) do |post, _opts, user|
      begin
        next unless post && user
        next if post.user_id != user.id
        next if post.post_number == 1  # bounty trigger requires a REPLY, not the OP

        # Find any open random_reach bounty on this topic where this user is invited
        bounty = ::DiscourseCoinEngine::Bounty
                   .where(topic_id: post.topic_id, status: 'open', bounty_type: 'random_reach')
                   .order(:id)
                   .find { |b|
                     ::DiscourseCoinEngine::BountyInvitation.exists?(bounty_id: b.id, user_id: user.id) &&
                     !::DiscourseCoinEngine::BountyClaim.exists?(bounty_id: b.id, user_id: user.id)
                   }
        next unless bounty
        ::DiscourseCoinEngine::BountyDispatcher.attempt_claim!(bounty, user, post)
      rescue StandardError => e
        Rails.logger.warn("[coin_engine] post_created bounty hook: #{e.class}: #{e.message}")
      end
    end
  end


  # v0.8.2: validate the Solana wallet user_field on every user save. Strip if invalid.
  on(:user_updated) do |user|
    field_id = SiteSetting.coin_engine_solana_field_id.to_i rescue 0
    next if field_id <= 0
    key = "user_field_#{field_id}"
    val = user.custom_fields[key].to_s.strip
    next if val.empty?
    unless DiscourseCoinEngine.valid_solana_address?(val)
      user.custom_fields[key] = nil
      user.save_custom_fields(true)
      Rails.logger.warn("[coin_engine] stripped invalid Solana wallet from user #{user.id}: #{val[0,8]}...")
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
    DiscourseCoinEngine::PublicLedgerController,
    DiscourseCoinEngine::QuestsController,
    DiscourseCoinEngine::MeController,
    DiscourseCoinEngine::AdminVerifiedProsController,
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
