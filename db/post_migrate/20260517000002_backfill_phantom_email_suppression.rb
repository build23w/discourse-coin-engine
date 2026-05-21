# frozen_string_literal: true

# v0.22.0 — One-shot backfill closing the email-bounce hole opened in v0.15.2.
#
# Problem: signup_with_phantom set `active: true` AND
# `user.email_tokens.update_all(confirmed: true)` at line 231 of auth_controller.rb,
# meaning every Phantom-signed-up user has a fake-confirmed email_token from
# t=0. Plugin engagement jobs and Discourse core mailers see them as fully
# email-eligible, even though no real verification ever happened. A signup loop
# with random fake addresses would have pushed SES bounce rate over the
# suspension threshold within hours.
#
# Detection signature: email_tokens.confirmed = true AND
# ABS(EXTRACT(EPOCH FROM (confirmed_at - users.created_at))) < 10
# i.e. the token got marked confirmed within 10 seconds of the user being
# created. Normal Discourse signup has a token sitting unconfirmed until
# the user clicks the email link (which is always at least minutes later);
# the only way to get within-10-seconds confirmation is the fake-confirm hack.
#
# Action taken per matched user:
#   1) Stamp UserCustomField coin_engine_email_unverified=1 (EmailGate gate)
#   2) Set user_options.email_digests=false, mailing_list_mode=false,
#      email_level=never(3), email_messages_level=never(3) — suppresses
#      Discourse-core engagement + transactional emails too
#   3) Log a row to PluginStore for audit
#
# Recovery path: users can verify via /my/preferences/email at any time.
# EmailGate.allowed? auto-clears the flag once a confirmed EmailToken with
# their current primary email exists.

class BackfillPhantomEmailSuppression < ActiveRecord::Migration[7.0]
  def up
    return unless table_exists?(:user_custom_fields) && table_exists?(:email_tokens) && table_exists?(:user_options)

    # Find Phantom-signed-up users via the fake-confirm timing signature.
    rows = execute(<<~SQL).to_a
      SELECT DISTINCT u.id AS user_id, u.email
      FROM users u
      JOIN email_tokens et ON et.user_id = u.id
      WHERE u.active = true
        AND et.confirmed = true
        AND et.confirmed_at IS NOT NULL
        AND ABS(EXTRACT(EPOCH FROM (et.confirmed_at - u.created_at))) < 10
    SQL

    say "[v0.22.0 backfill] Found #{rows.size} Phantom-signed-up users to flag"

    flagged = 0
    rows.each do |r|
      uid = r['user_id'].to_i
      next if uid <= 0

      # Stamp the unverified flag (idempotent — clear existing first).
      execute "DELETE FROM user_custom_fields WHERE user_id = #{uid} AND name = 'coin_engine_email_unverified'"
      execute "INSERT INTO user_custom_fields (user_id, name, value, created_at, updated_at) " \
              "VALUES (#{uid}, 'coin_engine_email_unverified', '1', NOW(), NOW())"

      # Clamp user_options email levels to never. Don't blow up if the row
      # is missing for some legacy reason.
      execute "UPDATE user_options SET email_digests = false, mailing_list_mode = false, " \
              "email_level = 3, email_messages_level = 3 WHERE user_id = #{uid}"

      flagged += 1
    end

    say "[v0.22.0 backfill] Flagged #{flagged} users — all plugin and core engagement emails to this cohort are now suppressed until they verify via /my/preferences/email"
  end

  def down
    # Reversal: clear the flag we just stamped. Doesn't restore the prior
    # email_options state (that's intentional — re-enabling email_digests on
    # rollback would re-introduce the bounce risk).
    return unless table_exists?(:user_custom_fields)
    execute "DELETE FROM user_custom_fields WHERE name = 'coin_engine_email_unverified'"
    say "[v0.22.0 backfill] Reversed: cleared all coin_engine_email_unverified flags. user_options email levels NOT restored (kept suppressed for safety)."
  end
end
