# discourse-coin-engine

A configurable, brandable community-coin gamification engine for Discourse. Pairs with the **hrr-ux-pack** theme component to power a $RENO-style coin economy: leaderboards, tier titles, public payment ledger, weekly digest emails, streak nudges, dormant re-engagement, and an admin airdrop endpoint.

Defaults to **$RENO** (the home.renovation.reviews community coin) but every brand value is admin-configurable. The companion theme component falls back to $RENO defaults if this plugin is uninstalled.

## What this plugin gives you

### Configuration surface (admin site settings)
- Coin name (`$RENO`, `$BUILD`, `⊙CRED`, anything)
- Coin symbol
- Brand accent color
- Welcome topic ID + Payment Ledger topic ID
- Tier ladder: thresholds + tier names (pipe-separated, parallel arrays)
- Solana wallet user-field ID
- Anti-abuse cap on coins-per-hour-per-user

### API endpoints (consumed by the theme component)
- `GET /coin-engine/config.json` — full brand + tier + feature config
- `GET /coin-engine/leaderboard.json?period=week|month|all` — period-filtered leaderboards with personal rank
- `GET /coin-engine/payments.json` — recent rows from the public payment ledger
- `GET /coin-engine/user/:username/recap.json` — weekly stats: earnings, rank delta, new badges, streak
- `GET /coin-engine/user/:username/streak.json` — server-computed visit streak (current, longest, at-risk flag)
- `POST /coin-engine/admin/airdrop.json` — admin-only manual coin grant + auto-append to ledger + optional email + optional webhook

### Email engagement (Sidekiq scheduled jobs)
All gated by `coin_engine_emails_enabled` and individual feature switches:
- **Weekly leaderboard digest** — top earners + your rank delta, sent weekly
- **Personal weekly recap** — your earnings, new badges, streak, sent weekly
- **Streak warning** — daily, when your streak is at risk
- **Dormant re-engagement** — weekly, "here's what you missed" for users dormant 7+ days
- **Tier-up notification** — event-driven, when you cross a tier
- **Airdrop notification** — when an admin manually credits your account

### Server-side state
- Real visit-streak computation from `user_visits` (replaces the localStorage estimate)
- Period-filtered leaderboard queries against `gamification_scores` with proper SUM aggregation
- Public ledger parsing — reads the markdown table in your ledger topic and exposes structured rows over JSON

### Anti-abuse
- Configurable max-coins-per-hour cap per user (reserved for future event-hooked enforcement)
- Negative-coin penalty hooks reserved for spam-flag integrations

### Outbound webhook
- POST coin engine events (tier_up, airdrop, milestone, weekly_digest_sent) to a configured URL — wire to Zapier, n8n, Discord, anywhere.

## Install

See `INSTALL.md`. The short version:

1. Add the repo URL to your Discourse `app.yml` under `hooks:` -> `before_code:`.
2. Rebuild the container.
3. Visit Admin -> Settings -> Plugins, find "coin engine", enable.
4. Configure the brand: coin name, tier thresholds, topic IDs.
5. Optionally enable each email feature individually.

## Configuration reference

Every setting starts with `coin_engine_`. See `config/settings.yml` for the canonical list. The most-used ones:

| Setting | Default | Notes |
|---|---|---|
| `coin_engine_enabled` | `true` | Master switch. False -> all endpoints 404, all jobs no-op. |
| `coin_engine_coin_name` | `$RENO` | Display name in widgets and emails. |
| `coin_engine_coin_symbol` | `$` | One-char symbol. |
| `coin_engine_brand_color` | `#ff6b35` | Hex accent in email templates. |
| `coin_engine_welcome_topic_id` | `47008` | Linked from widgets and digest emails. |
| `coin_engine_ledger_topic_id` | `47016` | Source for the payments endpoint, append target for airdrops. |
| `coin_engine_tier_thresholds` | `0|100|1000|5000|25000|50000` | Pipe-separated; must match tier_names length. |
| `coin_engine_tier_names` | `Beginner|Bronze|Silver|Gold|Platinum|Diamond` | Pipe-separated; same length as thresholds. |
| `coin_engine_solana_field_id` | `1` | Discourse user_field id holding the wallet. |
| `coin_engine_emails_enabled` | `false` | Master switch for ALL email jobs. |
| `coin_engine_weekly_digest_enabled` | `false` | Top-N leaderboard digest, weekly. |
| `coin_engine_personal_recap_enabled` | `false` | Per-user earnings recap, weekly. |
| `coin_engine_streak_warning_enabled` | `false` | Daily nudge for at-risk streaks. |
| `coin_engine_dormant_reengage_enabled` | `false` | Weekly "what you missed" for dormant users. |
| `coin_engine_dormant_days_threshold` | `7` | User considered dormant after N days. |

## Component pairing

The theme component **hrr-ux-pack** (separately deployed at `theme id 31` on home.renovation.reviews) consumes this plugin's settings via the `Discourse.SiteSettings.coin_engine_*` exposure (settings declared `client: true`). When the plugin is missing, the component falls back to hardcoded $RENO defaults.

## Compatibility

**Discourse 3.2 - 2026.5+**. The plugin keeps a small API surface so 2026.x rebuilds don't break.

Compat fix history:
- **v0.28.1** (2026-06-03) -- fix `post_votes#cast` 500: `Topic#first_post_id` doesn't exist (NoMethodError on voting another user's topic). Replaced with a safe `Post.where(topic_id:, post_number:1).pluck(:id).first` lookup. Found via live testing — self-vote block + rate limits verified working.
- **v0.28.0** (2026-06-03) -- **Reddit-style feed voting wired to $RENO.** New `coin_engine_post_votes` table + `PostVote` model; `post_votes#cast` (toggle/switch up/down), `#batch` (scores+my_vote for the feed), `#top` (most-upvoted, 30d). Authors earn $RENO on UPVOTES with layered anti-abuse: voter must be trust_level>=1 (configurable) — kills TL0 throwaways; rolling rate limits (30/hr, 200/day); reward only from eligible voters (TL>=1 AND account age>=3d AND not self); per-topic + per-author DAILY $RENO caps; downvotes never pay; un-voting never claws back. Real-time MessageBus notice to the author on reward. New site settings: coin_engine_feed_voting_enabled, vote_reward_amount(2), daily_cap_per_topic(50)/per_author(200), min_trust_level(1), min_account_age_days(3).
- **v0.27.0** (2026-06-03) -- **on-chain peer-to-peer SOL tipping.** Members can tip real SOL directly to each other via Phantom (sender's wallet → recipient's linked wallet, no treasury). New `coin_engine_sol_tips` table + `SolTip` model; `economy#sol_tip_initiate` (records pending tip + returns recipient wallet & memo), `economy#sol_tip_confirm` (records sig + queues verification), `economy#list_sol_tips` (received). `CoinEngineConfirmSolTip` job verifies the transfer landed on-chain (recipient got >= amount, memo present) and pushes a real-time MessageBus notice to the recipient. Profile 'Tip SOL' UI in the theme.
- **v0.26.0** (2026-06-03) -- **web3 expansion: live on-chain $RENO reads.** Two new RPC-proxy endpoints. `GET /coin-engine/solana/token_supply.json` (PUBLIC, 5-min cached) returns live circulating supply via `getTokenSupply`. `GET /coin-engine/solana/token_balance.json[?owner=]` returns a wallet's real on-chain $RENO balance via `getTokenAccountsByOwner` (defaults to the caller's linked wallet, sums all ATAs). Both ride the hardened multi-RPC `call_rpc` (retries/fallbacks). Surfaced in the theme: an on-chain $RENO card on the Community Pulse (supply + your balance + Solscan link) and a live on-chain balance pill on profiles.
- **v0.25.0** (2026-06-03) -- **Squads go social.** (1) USER-created squads: `POST /coin-engine/social/squads.json` (creator becomes captain) with anti-abuse (3/day rate limit, trust_level>=1, one-squad-per-user, soft 250 cap, auto-deduped slug). (2) Captain editing: `PUT /coin-engine/social/squads/:slug.json` (captain/staff can change icon/color/region/description). (3) Captaincy succession: when a captain leaves, the longest-tenured member is promoted so squads are never leaderless. (4) Enriched `show_squad` detail (members with scores + avatars, sorted, board rank, viewer role). (5) A public, shareable, SEO-able squad PAGE at `/coin-engine/squad/:slug` (server-rendered standalone HTML with OpenGraph tags + member roster).
- **v0.24.1** (2026-06-03) -- **THE staking bug.** `plugin.rb` loaded the empty `stake.rb` stub but never `sol_stake.rb`, so `::DiscourseCoinEngine::SolStake` was undefined at runtime and every staking endpoint (`index`/`initiate`/`confirm`/`unstake_request`) plus the `coin_engine_confirm_stake` job threw `NameError: uninitialized constant ...::SolStake` and 500'd. This is the actual reason 'staking does not work'. Added the missing `load` for sol_stake.rb. (Found by live-browser probe once v0.23.5's diagnosable-error mapping replaced the opaque raw 500 with the real NameError.)
- **v0.24.0** (2026-06-03) -- **Squads / Regional Teams (feature).** Wires up the Phase-3 squad backend that had models + join/leave routes since v0.6.0 but no surface or scoring. Adds: a seed migration creating 8 GTA regional squads (Downtown Core, North York, Scarborough, Etobicoke, Mississauga, Brampton, Vaughan, Markham); a `DiscourseCoinEngineRefreshSquadScores` scheduled job (every 30 min) that recomputes each squad's member_count + total_score from members' lifetime gamification scores via `coin_user_total_bulk`; `social#my_squad` + an enhanced `list_squads` (now returns per-squad rank + a `joined` flag + `my_squad_id`); and `AdminSocialController` JSON CRUD (`/admin/coin-engine/social/squads(.json)`) so staff can create/rename/recolor/enable/delete squads without a console. Paired with a 'Squads' tab in the $RENO Hub (hrr-ux-pack).
- **v0.23.5** (2026-06-03) -- **staking reliability.** Two fixes prompted by a 'staking doesn't work' report. (1) `SolanaController#call_rpc` (the browser's blockhash proxy that every Phantom stake/buy/store tx needs) now retries each RPC twice with a longer timeout — a single transient RPC blip used to bubble up as a 503 and abort the tx build before Phantom opened. (2) Added `StakingController` + `SolanaController` to the global JSON-exception rescue list so their unexpected errors return a diagnosable `coin_engine_exception` payload (with correct status mapping) instead of an opaque raw 500. NOTE: the live deployment was found to be STALE — `/coin-engine/staking/pending_payouts.json` (a v0.21.0 route) 404s and `stakes.json` throws the classic bare-`Stake`-vs-`SolStake` 500 that v0.21.0 already fixed in this repo. The live forum must be rebuilt from current main for staking to work end-to-end.
- **v0.23.4** (2026-06-03) -- **exception-status mapping.** The global `rescue_from StandardError` in `plugin.rb` (wrapping 15 phase/admin controllers) was rendering *every* raised exception as HTTP 500 — including `Discourse::NotLoggedIn` (so a simple `requires_login` rejection on e.g. `economy#list_bounties`, `identity#list_photo_bounties`, `social#list_spotlights` returned a 500 + backtrace to anon visitors and crawlers), plus `RateLimiter::LimitExceeded`, `Discourse::InvalidParameters` and `ActiveRecord::RecordInvalid`. Now maps known Discourse/AR exceptions to their correct status (403/404/400/429/422) and only logs + backtraces genuinely-unexpected 500s. Cleans up error monitoring and lets the client distinguish auth/rate-limit from real server errors.
- **v0.23.3** (2026-06-03) -- **wallet user-field dupe-row fix.** `coin_engine_generate_wallet` (runs on every signup via `:user_created`) and `wallet_controller#seed` still wrote the wallet pubkey with `UserCustomField.upsert(unique_by: [:user_id, :name])`. `user_custom_fields` has no unique index on `(user_id, name)`, so that upsert silently degrades to a plain INSERT and stacks duplicate rows; `User#user_fields[fid]` then comma-concats them (`<pk>,<pk>,...`) and trips the 32-44 Base58 check downstream. Both paths now delete-then-insert inside a transaction (matching `connect_phantom`/`auth_controller`), which also self-heals users already corrupted by prior runs. Also: `social#list_spotlights` is now public (`requires_login except:`) to match its sibling `list_squads`/`show_squad`, so the spotlight feed can render for anon visitors.
- **v0.4.1** (2026-04-29) -- the v0.4.0 connector at `admin-plugin-config-page-coin-engine` outlet didn't render in Discourse 2026.5 (the outlet either doesn't exist under `use_new_show_route: true` or has a different name). Replaced with the modern Discourse pattern: ship `admin/assets/javascripts/discourse/admin-coin-engine-route-map.js` declaring `this.route("payments")`. Discourse auto-mounts this as a child route of `adminPlugins.show.coin-engine`, which renders as a **tab at the top of the Coin Engine admin page next to "Settings"**. Tab label comes from `admin_js.coin_engine.payments.title`. The tab content lives at `templates/admin/plugins/show/payments.hbs` and iframes the existing `/admin/plugins/coin-engine/embed` URL. The old connector .hbs is now an empty no-op.
- **v0.3.1** (2026-04-29) -- removed the `add_admin_route 'coin_engine.title', 'coin-engine'` registration. It was creating a sidebar link that Ember tried to resolve as a client-side route (`adminPlugins.coin-engine`) -- and since we ship server-rendered HTML rather than an Ember module, the link errored with **"Unable to configure link to 'Coin Engine'. Ensure ad-blockers are disabled and try reloading the page."** The page itself works; just bookmark `/admin/plugins/coin-engine` directly. To re-enable a sidebar link in a future version, ship an Ember admin module + use `add_admin_route 'coin_engine.title', 'coin-engine', use_new_show_route: true`.
- **v0.3.0** (2026-04-29) -- new admin UI for manual payments. Adds `coin_engine_payments` table (post_migrate), `DiscourseCoinEngine::Payment` model, `AdminPaymentsController` with index/list/search_users/user_payments/create/update_tx_signature endpoints, server-rendered admin page at `/admin/plugins/coin-engine`, manual_payment_receipt mailer + email template, receipt PM creation, `EmailThrottle` lib (max 1 engagement email per user per day), polished weekly_digest + personal_recap templates, new daily_top_picks scheduled job.
- **v0.2.3** (2026-04-29) -- raw SQL in `coin_engine_score` / `coin_engine_rank` serializers (the `::GamificationScore` constant doesn't exist on this install; the model is namespaced `DiscourseGamification::GamificationScore`). The original `rescue` was silently swallowing the NameError and returning 0.
- **v0.2.2** (2026-04-29) -- removed `register_asset 'stylesheets/coin-engine-admin.scss', :admin` from `plugin.rb`. The referenced file didn't exist in the repo, so `assets:precompile` hit `Sass::CompileError: Can't find stylesheet to import.` during container rebuild.
- **v0.2.1** (2026-04-29) -- replaced `User::USERNAME_ROUTE_FORMAT` with inline regex `%r{[\w.\-]+?}` in route constraints. That constant was removed in Discourse 2026.x and crashed plugin boot during `db:migrate`.

If you hit a `NameError` / `uninitialized constant` / `Can't find stylesheet` failure on rebuild, please open an issue with the stack trace.

## License

MIT.
