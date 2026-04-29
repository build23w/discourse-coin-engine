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
- **v0.3.0** (2026-04-29) -- new admin UI for manual payments. Adds `coin_engine_payments` table (post_migrate), `DiscourseCoinEngine::Payment` model, `AdminPaymentsController` with index/list/search_users/user_payments/create/update_tx_signature endpoints, server-rendered admin page at `/admin/plugins/coin-engine`, manual_payment_receipt mailer + email template, receipt PM creation, `EmailThrottle` lib (max 1 engagement email per user per day), polished weekly_digest + personal_recap templates, new daily_top_picks scheduled job.
- **v0.2.3** (2026-04-29) -- raw SQL in `coin_engine_score` / `coin_engine_rank` serializers (the `::GamificationScore` constant doesn't exist on this install; the model is namespaced `DiscourseGamification::GamificationScore`). The original `rescue` was silently swallowing the NameError and returning 0.
- **v0.2.2** (2026-04-29) -- removed `register_asset 'stylesheets/coin-engine-admin.scss', :admin` from `plugin.rb`. The referenced file didn't exist in the repo, so `assets:precompile` hit `Sass::CompileError: Can't find stylesheet to import.` during container rebuild.
- **v0.2.1** (2026-04-29) -- replaced `User::USERNAME_ROUTE_FORMAT` with inline regex `%r{[\w.\-]+?}` in route constraints. That constant was removed in Discourse 2026.x and crashed plugin boot during `db:migrate`.

If you hit a `NameError` / `uninitialized constant` / `Can't find stylesheet` failure on rebuild, please open an issue with the stack trace.

## License

MIT.
