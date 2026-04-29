# Installation -- discourse-coin-engine

## Prerequisites
- Discourse 3.2 or newer
- The `discourse-gamification` plugin installed and configured (this plugin reads its `gamification_scores` table)
- Optional: a public Payment Ledger topic (for the airdrop endpoint to append rows)
- Optional: a Solana wallet user-field if you want wallet-aware emails

## 1. Add the repo to your Discourse container

Edit `/var/discourse/containers/app.yml` on your Discourse server. Under the `hooks:` -> `before_code:` block, add:

```yaml
hooks:
  before_code:
    - exec:
        cd: $home/plugins
        cmd:
          - git clone https://github.com/lf-builders/discourse-coin-engine.git
```

(Replace the URL with whichever git remote you push the plugin to.)

## 2. Rebuild the container

```bash
cd /var/discourse
./launcher rebuild app
```

Wait ~10 minutes. The plugin's controllers, jobs, and migrations run during the rebuild.

## 3. Enable the plugin

After Discourse is back up:
1. Visit **Admin -> Settings -> Plugins**.
2. Search "coin engine".
3. Set `coin_engine_enabled` to `true`.

## 4. Configure your brand

In the same settings page:
- `coin_engine_coin_name` -- defaults to `$RENO`. Change to whatever your community coin is called.
- `coin_engine_coin_symbol` -- one-character symbol.
- `coin_engine_brand_color` -- hex color for email accents.
- `coin_engine_welcome_topic_id` -- the topic that explains your coin to new users.
- `coin_engine_ledger_topic_id` -- the public payment ledger topic.
- `coin_engine_tier_thresholds` -- pipe-separated coin amounts. Defaults to `0|100|1000|5000|25000|50000`.
- `coin_engine_tier_names` -- pipe-separated tier names. Defaults to `Beginner|Bronze|Silver|Gold|Platinum|Diamond`. **Must match the length of tier_thresholds.**

## 5. (Optional) Enable email engagement

Each email type is opt-in:
1. Set `coin_engine_emails_enabled` to `true` (master switch).
2. Then enable any of:
   - `coin_engine_weekly_digest_enabled`
   - `coin_engine_personal_recap_enabled`
   - `coin_engine_streak_warning_enabled`
   - `coin_engine_dormant_reengage_enabled`
   - `coin_engine_tier_up_email_enabled`

Schedule (UTC):
- Weekly digest + personal recap: every 7 days
- Streak warning: daily
- Dormant re-engagement: weekly

User must have `email_digests` enabled in their preferences to receive any of these.

## 6. (Optional) Configure the outbound webhook

`coin_engine_webhook_url` -- if set, coin engine events POST to this URL with a JSON body.

`coin_engine_webhook_events` -- comma-separated event types to push. Options: `tier_up,airdrop,milestone,weekly_digest_sent`. Default: `tier_up,airdrop,milestone`.

## 7. Test the API endpoints

```bash
# Public config
curl -H 'User-Agent: Mozilla/5.0' https://your-forum.example/coin-engine/config.json

# Period-filtered leaderboard
curl -H 'User-Agent: Mozilla/5.0' 'https://your-forum.example/coin-engine/leaderboard.json?period=week&limit=10'

# Recent payments
curl -H 'User-Agent: Mozilla/5.0' https://your-forum.example/coin-engine/payments.json

# User recap (public)
curl -H 'User-Agent: Mozilla/5.0' https://your-forum.example/coin-engine/user/SOMEUSER/recap.json

# Admin airdrop (requires staff API key)
curl -X POST -H 'Api-Key: ...' -H 'Api-Username: system' -H 'Content-Type: application/json' \
  -d '{"username":"target_user","amount":250,"reason":"Contest winner"}' \
  https://your-forum.example/coin-engine/admin/airdrop.json
```

## 8. Companion theme component

Pair with the `hrr-ux-pack` theme component to surface this configuration in the on-page widget. The component auto-detects this plugin via `Discourse.SiteSettings.coin_engine_*` and falls back to `$RENO` defaults if missing.

## Uninstall

1. Set `coin_engine_enabled` to `false` (or remove the plugin's git block from `app.yml`).
2. Rebuild the container.
3. The companion theme component will fall back to its built-in `$RENO` defaults; users see no functional regression beyond the disabled emails.

No data is destroyed on uninstall. The `gamification_scores` table is owned by `discourse-gamification` and untouched.
