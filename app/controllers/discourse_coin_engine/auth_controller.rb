# frozen_string_literal: true

# v0.15.0 - Phantom-based signup.
#
# Lets visitors sign up by connecting their Phantom wallet, then filling in
# username/email/password. The Phantom pubkey is linked to the new account
# atomically with creation, and we log them in via Discourse's log_on_user
# helper so they don't have to verify email separately.
#
# Why a custom endpoint instead of the standard /u POST:
#   - Standard signup flow requires email verification (we want one-step).
#   - Standard flow doesn't atomically attach a user_field, so a network blip
#     between user create and wallet link would leave the wallet unbound.
#   - Standard flow doesn't return a session — we need log_on_user to land
#     the user on a logged-in homepage.
#
# Honors:
#   - SiteSetting.allow_new_registrations  (refuses when false)
#   - SiteSetting.must_approve_users       (creates but doesn't auto-login if true)
#   - SiteSetting.min_password_length      (server-side check)
#   - SiteSetting.invite_only              (refuses when true)
#
# Already-logged-in users hit a 422 with a hint to use the FAB Connect Phantom
# instead — this endpoint is for sign-up, not for re-linking.

module DiscourseCoinEngine
  class AuthController < ::ApplicationController
    skip_before_action :ensure_logged_in,        raise: false
    skip_before_action :redirect_to_login_if_required, raise: false
    skip_before_action :check_xhr,               raise: false

    SOLANA_PUBKEY_RE = /\A[1-9A-HJ-NP-Za-km-z]{32,44}\z/.freeze

    # POST /coin-engine/auth/signup_with_phantom.json
    # Body: { public_key, username, email, password }
    def signup_with_phantom
      Rails.logger.info("[coin_engine.auth] signup_with_phantom ip=#{request.remote_ip} ua=#{request.user_agent.to_s[0,120]}")

      if current_user
        return render json: {
          errors: ['You are already logged in. Use the Connect Phantom button in the wallet panel instead.']
        }, status: 422
      end

      unless SiteSetting.allow_new_registrations
        return render json: { errors: ['New registrations are currently disabled.'] }, status: 403
      end

      if SiteSetting.invite_only
        return render json: { errors: ['This forum is invite-only. Ask an existing member for an invite link.'] }, status: 403
      end

      RateLimiter.new(nil, "phantom_signup_#{request.remote_ip}", 5, 1.hour).performed!

      pubkey   = params[:public_key].to_s.strip
      username = params[:username].to_s.strip
      email    = params[:email].to_s.strip.downcase
      password = params[:password].to_s

      # ---- Validation ----
      unless pubkey.match?(SOLANA_PUBKEY_RE)
        return render json: { errors: ['That is not a valid Solana wallet address.'] }, status: 422
      end

      if username.empty? || email.empty? || password.empty?
        return render json: { errors: ['Username, email, and password are all required.'] }, status: 422
      end

      min_pw = SiteSetting.min_password_length.to_i
      if password.length < min_pw
        return render json: { errors: ["Password must be at least #{min_pw} characters."] }, status: 422
      end

      # Discourse normalizes usernames to lowercase + replaces some chars; defer to it.
      # But cheap sanity checks here so we get a clear error message.
      unless username =~ /\A[\w.\-]{2,20}\z/
        return render json: { errors: ['Username must be 2-20 characters, letters/numbers/dots/dashes/underscores only.'] }, status: 422
      end
      unless email.include?('@') && email.length >= 5
        return render json: { errors: ['That email address looks invalid.'] }, status: 422
      end

      # ---- Already-linked check ----
      field_id = (SiteSetting.coin_engine_solana_wallet_user_field_id rescue 1).to_i
      if ::UserCustomField.exists?(name: "user_field_#{field_id}", value: pubkey)
        return render json: {
          errors: ['This Phantom wallet is already linked to another account. Sign in with that account instead.']
        }, status: 422
      end

      # ---- Create user + link wallet atomically ----
      user = nil
      begin
        ::ActiveRecord::Base.transaction do
          user = ::User.new(
            username:                username,
            email:                   email,
            password:                password,
            active:                  true,                    # skip email verification
            approved:                !SiteSetting.must_approve_users,
            ip_address:              request.remote_ip,
            registration_ip_address: request.remote_ip,
            trust_level:             ::TrustLevel.levels[:newuser],
          )
          user.password_required!
          user.save!

          # Wallet link — delete-then-insert (no unique index on user_custom_fields,
          # see feedback memory: upsert silently dupes).
          ::UserCustomField.where(user_id: user.id, name: "user_field_#{field_id}").delete_all
          ::UserCustomField.create!(
            user_id: user.id,
            name:    "user_field_#{field_id}",
            value:   pubkey,
          )
        end
      rescue ::ActiveRecord::RecordInvalid => e
        return render json: { errors: e.record.errors.full_messages }, status: 422
      end

      # ---- Log them in (only if approved) ----
      if user.approved?
        log_on_user(user)
        Rails.logger.info("[coin_engine.auth] phantom signup OK user=#{user.id} username=#{user.username} pubkey=#{pubkey}")
        render json: {
          ok:       true,
          user:     { id: user.id, username: user.username },
          redirect: '/',
          message:  "Welcome, #{user.username}! Your account is ready.",
        }
      else
        Rails.logger.info("[coin_engine.auth] phantom signup pending-approval user=#{user.id} username=#{user.username}")
        render json: {
          ok:               true,
          user:             { id: user.id, username: user.username },
          requires_approval: true,
          message:          "Account created. An admin needs to approve your account before you can sign in.",
        }
      end
    rescue RateLimiter::LimitExceeded => e
      render json: { errors: ["Too many signup attempts from this IP. Wait #{e.available_in}s."] }, status: 429
    rescue StandardError => e
      Rails.logger.error("[coin_engine.auth] signup_with_phantom failed: #{e.class}: #{e.message[0,300]}\n#{e.backtrace[0,5].join("\n")}")
      render json: { errors: ['Could not create account. Try again in a moment.'] }, status: 500
    end

    # GET /coin-engine/auth/phantom_taken.json?public_key=...
    # Quick pre-flight: lets the modal warn the user before they fill in the form
    # if their wallet is already linked to an existing account.
    def phantom_taken
      pubkey = params[:public_key].to_s.strip
      unless pubkey.match?(SOLANA_PUBKEY_RE)
        return render json: { ok: false, taken: false, error: 'invalid_pubkey' }
      end

      field_id = (SiteSetting.coin_engine_solana_wallet_user_field_id rescue 1).to_i
      taken = ::UserCustomField.exists?(name: "user_field_#{field_id}", value: pubkey)

      render json: { ok: true, taken: taken }
    end
  end
end
