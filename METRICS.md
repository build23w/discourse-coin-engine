# Metrics & Analytics Catalog — home.renovation.reviews ecosystem

Everything the platform tracks and measures, where it lives, and how it's computed.
Spans `discourse-coin-engine` (this repo), `discourse-shorts`, `discourse-latest-geo`,
and the theme layer (hrr-ux-pack id=31, hrr-feed-images id=33).

---

## 1. Economy ($RENO) — coin-engine

| Metric | Storage | Notes |
|---|---|---|
| Daily score / earnings | `gamification_scores` (user_id, date, score) | Single write path: `DiscourseCoinEngine.credit_score` — never raw SQL |
| All-time / weekly rank | `LeaderboardQuery` (period: week/all) + refreshed materialized views (`refresh_leaderboard_views` job) | Shared rank cache (v0.31.0) |
| Tier | Derived from score thresholds | Animated tier ring on profile; tier-up email (`coin_engine_tier_up_email_enabled`) |
| Tips (forum) | `coin_engine_tips` | Per-post tip pill; sender/recipient/amount |
| Tips (on-chain SOL) | `coin_engine_sol_tips` + tx signature | Phantom-signed P2P transfer, server-confirmed via `coin_engine_confirm_sol_tip` job |
| Stakes (RENO, Phase 2) | `Stake` model | Forum-side staking |
| Stakes (on-chain SOL) | `SolStake` + deferred payout job | NEVER use bare `Stake` for on-chain flow |
| Meteora Stake2Earn | On-chain (M3M3 pool) | 69.86% fee share to top-1000 stakers; parallel to forum stakes |
| Bounties / rounds | `coin_engine_bounties` + `expire_bounty_round` job | Award totals per user |
| Shop / redemptions | purchase + fulfillment tables (`fulfill_store_purchase` job) | |
| Auctions, chests, freezes | respective tables | Daily chest claim = engagement ping |
| Airdrops | admin endpoint + `random_airdrop` scheduled job + SSRF-defended webhook | Per-user receipt + notifier event |
| Payment receipts / ledger | paginated profile receipts (3/page, cap 30) + public ledger endpoints | |
| Wallets | custodial keypairs + Phantom-linked pubkeys (dupe-field fix v0.23.3) | On-chain $RENO supply + balance surfaced live |
| Credit events (real-time) | MessageBus `/coin-engine/credits/{user_id}` | Reason vocabulary: tip/bounty/airdrop/quest_reward/manual_payment/stake_confirmed/... `Notifier.credit!` is the unified entry point (MessageBus + PM→email for offline users) |

## 2. Voting & content quality — coin-engine

- Post + topic up/down votes (`votes/batch.json` hydration, $RENO rewards to authors with daily caps).
- Top Reply: `top_replies` endpoint (v0.30.0) — highest-upvoted reply pinned as a card on topic pages.
- Quests: server-verified claims (`quests/claim_batch.json`, idempotent, per-user-per-day cap). Client caches terminal results; non-terminal retries cooldown 6h (v2026-06-05).

## 3. Social graph — coin-engine (v0.31+)

- Follows (`coin_engine_follows`, unique follower→following): follower/following counts (cached 60s).
- Reposts (`coin_engine_reposts`, unique user+kind+ref): topics AND shorts, share-to-profile.
- Followed feed: `DISTINCT ON (kind, ref_id)`, per-author cap 3, 30-day window — dedupe guaranteed server-side.
- Profile analytics endpoint (cached 120s): followers, following, reposts_made, reposts_received + engagement aggregates.
- Rate limits: follow 120/day, repost 60/day.

## 4. Squads — coin-engine

- `coin_engine_squads`: member_count, total_score (sum of member $RENO, `refresh_squad_scores` job), squad rank.
- Public SEO page per squad (`/coin-engine/squad/:slug`) with OpenGraph.
- Squad HQ (v0.32.0): auto subcategory + mirror group at member threshold (settings: `coin_engine_squad_hq_*`, parent category 424).

## 5. Verified Pro & Ranking Pins — coin-engine

- `VerifiedPro` (verification_status, company_name, verified_at) + application funnel (min account age / TL / posts, reapply cooldown).
- Pin awards: `user_custom_fields.coin_engine_pin_awards` (top3 / aplus / fivestar). Admin-granted.
- Dynamic SVG pins `/coin-engine/pin/:username.svg` (30-min cache) — embeds on company sites are measurable referrers (look for `coin-engine/pin` in access logs / referrer reports).

## 6. Shorts — discourse-shorts

| Metric | Notes |
|---|---|
| views | +1 per watch ping |
| watch_seconds | summed real engagement time per short |
| likes / dislikes | per-user reaction rows; `rewarded` flag drives $RENO payout caps (per-short + per-author daily) |
| shares | share-intent count (per-IP throttled); ANY interaction (like/comment/share) makes an ingested short permanent in the recycler |
| comment_count + topic_id | server-side comment→auto-topic bridge (category 423) |
| source / priority | ingest vs owned vs submission; owned videos carry a gentle ranking nudge |
| Feed ranking | `(likes - dislikes + priority) DESC` — index payload cached 60s shared across viewers |

## 7. Geo & feed intelligence — discourse-latest-geo

- `rr_geo_tokens` per user (click-to-edit location widget, typeahead, recent chips).
- Geo-prioritized feed ranking (server) + user-category affinity cache + engagement-velocity term + time-bucket seeds + fresh-topic lottery (v0.7.0).

## 8. Theme-layer (client) measurements

- **Trending rail (`lf-trend`)**: score = `(3·replies + 2·likes + 0.15·views) × recency` (decay ~12h half-life), computed over the loaded feed. v0.16.0: topics matching the viewer's `rr_geo_tokens` get a 1.6× local boost + 📍 badge; the "in <place>" header renders only when ≥2 surfaced cards are genuinely local.
- **Trend breakdown card (`lf-tbk`)**: aggregates `/top.json?period=weekly` into category-level trends (topic volume + reply volume), Twitter-style ranked list, local 📍 flag, 15-min session cache.
- Heat tier on feed thumbs: `views + 5·likes + 10·posts ≥ 100`.
- Re-rank scoring on strong action / return-to-feed (location-heavy) + ε-greedy exploration.
- Visit streaks (localStorage, mirrored by server `streak_warning` job), daily chest, quest completion cache, card dismissals (`lf_wtf_dismiss` etc.).
- Activity timeline: core `/user_actions.json` (topics+replies) merged with reposts.

## 9. Email engagement — coin-engine

- Master switch `coin_engine_emails_enabled` (ON since 2026-06-05). Per-type switches for weekly digest, top picks, recap, dormant re-engage, streak warning, tier-up.
- `EmailThrottle`: hard cap 1 engagement email/user/day (custom field `coin_engine_last_email_day`). Transactional receipts exempt.
- `EmailGate`: suppresses placeholder (`@no-mail.invalid` Phantom signups), unverified, suspended/silenced. Fail-closed.

## 10. Where to watch it

- Per-profile: social analytics card + $RENO Wrapped year-in-review (theme 31).
- Site-wide: Community Pulse dashboard tab, leaderboard (`/leaderboard`), squad leaderboard.
- Admin: Discourse reports + coin-engine admin endpoints (verified pros stats, squads, airdrops).
