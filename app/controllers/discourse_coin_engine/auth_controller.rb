# frozen_string_literal: true

require 'base64'
require 'securerandom'
require 'openssl'
require 'net/http'
require 'json'

module DiscourseCoinEngine
  class AuthController < ::ApplicationController
    skip_before_action :ensure_logged_in,                raise: false
    skip_before_action :redirect_to_login_if_required,   raise: false
    skip_before_action :check_xhr,                       raise: false

    skip_before_action :verify_authenticity_token,       only: %i[signup_with_phantom phantom_taken signup_nonce signin_with_phantom signin_nonce], raise: false

    SOLANA_PUBKEY_RE   = /\A[1-9A-HJ-NP-Za-km-z]{32,44}\z/.freeze
    NONCE_TTL_SECONDS  = 5 * 60     # 5 minutes from issue to consume
    BASE58_ALPHABET    = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz'.freeze

    PUBLIC_RPC_FALLBACKS = [
      'https://solana-rpc.publicnode.com',
      'https://rpc.ankr.com/solana',
      'https://api.mainnet-beta.solana.com',
    ].freeze

    # GET /coin-engine/auth/signup_nonce.json?public_key=<pk>
    def signup_nonce
      pubkey = params[:public_key].to_s.strip
      unless pubkey.match?(SOLANA_PUBKEY_RE)
        return render json: { errors: ['Invalid Solana wallet address.'] }, status: 422
      end

      # Per-IP rate limit. Generous because users may retry on Phantom-decline.
      RateLimiter.new(nil, "phantom_nonce_#{request.remote_ip}", 30, 1.hour).performed!

      nonce  = SecureRandom.hex(16)
      domain = (SiteSetting.force_hostname.presence || ::Discourse.base_url.gsub(%r{^https?://}, '')).to_s
      issued = Time.zone.now.iso8601

      # SIWS-style message — clearly states what the user is signing,
      # which domain it binds to, and includes the nonce + timestamp.
      message = <<~MSG.strip
        #{domain} wants you to sign in with your Solana account.

        This signature only proves you control this wallet. It costs no SOL,
        creates no on-chain transaction, and will not appear in your wallet history.

        Nonce: #{nonce}
        Issued: #{issued}
      MSG

      Discourse.redis.setex("coin_engine_signup_nonce:#{pubkey}", NONCE_TTL_SECONDS, message)

      render json: {
        ok:         true,
        nonce:      nonce,
        message:    message,
        expires_in: NONCE_TTL_SECONDS,
      }
    rescue RateLimiter::LimitExceeded => e
      render json: { errors: ["Slow down. Wait #{e.available_in}s."] }, status: 429
    end

    # POST /coin-engine/auth/signup_with_phantom.json
    # Body: { public_key, signature, nonce, username, email, password }
    def signup_with_phantom
      Rails.logger.info("[coin_engine.auth] signup_with_phantom ip=#{request.remote_ip} ua=#{request.user_agent.to_s[0,120]}")

      if current_user
        return render json: { errors: ['You are already logged in. Use the FAB Connect Phantom button instead.'] }, status: 422
      end
      unless SiteSetting.allow_new_registrations
        return render json: { errors: ['New registrations are currently disabled.'] }, status: 403
      end
      if SiteSetting.invite_only
        return render json: { errors: ['This forum is invite-only.'] }, status: 403
      end

      RateLimiter.new(nil, "phantom_signup_#{request.remote_ip}", 5, 1.hour).performed!

      pubkey       = params[:public_key].to_s.strip
      signature_b64 = params[:signature].to_s.strip
      nonce         = params[:nonce].to_s.strip
      username      = params[:username].to_s.strip
      email         = params[:email].to_s.strip.downcase
      password      = params[:password].to_s

      # ---- Layer 1: signature verification ----
      unless pubkey.match?(SOLANA_PUBKEY_RE)
        return render json: { errors: ['Invalid Solana wallet address.'] }, status: 422
      end
      if signature_b64.empty? || nonce.empty?
        return render json: { errors: ['Wallet signature missing. Please retry the Phantom sign step.'] }, status: 422
      end

      stored_message = Discourse.redis.get("coin_engine_signup_nonce:#{pubkey}")
      if stored_message.nil?
        return render json: { errors: ['Signup challenge expired or never issued. Please retry.'] }, status: 422
      end
      unless stored_message.include?(nonce)
        return render json: { errors: ['Nonce does not match the issued challenge. Please retry.'] }, status: 422
      end

      unless verify_solana_signature(pubkey, stored_message, signature_b64)
        Rails.logger.warn("[coin_engine.auth] sig verify FAILED ip=#{request.remote_ip} pubkey=#{pubkey}")
        return render json: { errors: ['Wallet signature could not be verified.'] }, status: 401
      end

      # Consume the nonce (single-use)
      Discourse.redis.del("coin_engine_signup_nonce:#{pubkey}")

      # ---- Layer 2: on-chain activity gate (fail-open on RPC failure) ----
      # The check returns a tri-state. We ONLY block on :inactive (RPC
      # responded successfully and the wallet has zero signatures). On
      # :unknown (RPC failed / throttled / returned malformed data) we
      # pass the user through and log — free RPCs throttle this method
      # heavily and we don't want a legitimate user to fail signup just
      # because publicnode is rate-limiting today.
      if (SiteSetting.coin_engine_phantom_signup_require_activity rescue false)
        case wallet_activity_state(pubkey)
        when :inactive
          return render json: {
            errors: ['This wallet has no on-chain history. Send any tiny transaction to it (or from it) and try again.']
          }, status: 422
        when :unknown
          Rails.logger.warn("[coin_engine.auth] activity check unknown (RPC issue) — passing through ip=#{request.remote_ip} pubkey=#{pubkey}")
          # fall through (fail-open)
        end
      end

      # ---- Layer 3 (optional): minimum balance gate (fail-open on RPC failure) ----
      min_balance = (SiteSetting.coin_engine_phantom_signup_min_balance_lamports rescue 0).to_i
      if min_balance > 0
        bal = wallet_balance_lamports(pubkey)
        if bal.nil?
          Rails.logger.warn("[coin_engine.auth] balance check unknown (RPC issue) — passing through ip=#{request.remote_ip} pubkey=#{pubkey}")
          # fall through (fail-open)
        elsif bal < min_balance
          return render json: {
            errors: ["This wallet's balance is below the minimum required for signup (#{min_balance} lamports)."]
          }, status: 422
        end
      end

      if username.empty? || password.empty?
        return render json: { errors: ['Username and password are required.'] }, status: 422
      end
      min_pw = SiteSetting.min_password_length.to_i
      if password.length < min_pw
        return render json: { errors: ["Password must be at least #{min_pw} characters."] }, status: 422
      end
      unless username =~ /\A[\w.\-]{2,20}\z/
        return render json: { errors: ['Username must be 2-20 characters: letters, numbers, dots, dashes, underscores.'] }, status: 422
      end

      email_provided = !email.empty?
      if email_provided
        unless email.include?('@') && email.length >= 5
          return render json: { errors: ['That email address looks invalid.'] }, status: 422
        end
        if email.downcase.end_with?("@#{::DiscourseCoinEngine::EmailGate::PLACEHOLDER_DOMAIN}")
          return render json: { errors: ['That email domain is reserved. Leave the field blank to sign up without email.'] }, status: 422
        end
      else
        email = ::DiscourseCoinEngine::EmailGate.placeholder_email_for(pubkey)
      end

      # ---- Already-linked check ----
      field_id = (SiteSetting.coin_engine_solana_wallet_user_field_id rescue 1).to_i
      if ::UserCustomField.exists?(name: "user_field_#{field_id}", value: pubkey)
        return render json: {
          errors: ['This Phantom wallet is already linked to another account. Sign in with that account instead.']
        }, status: 422
      end

      # ---- Create user + link wallet atomically (Layer 4 = trust_level 0 + optional approval) ----
      # v0.22.0: account is active on-site (Phantom sig is our auth gate) but we
      # NEVER fake-confirm email_tokens anymore. Email lifecycle goes through
      # the standard Discourse prefs flow. EmailGate.suppress_user_emails! then
      # clamps user_options.email_* to never and stamps the appropriate flag,
      # so neither plugin email jobs nor Discourse core mailers will deliver
      # until the user verifies via /my/preferences/email.
      force_approval = !!(SiteSetting.coin_engine_phantom_signup_force_approval rescue false)
      requires_approval = SiteSetting.must_approve_users || force_approval
      user = nil
      begin
        ::ActiveRecord::Base.transaction do
          user = ::User.new(
            username:                username,
            email:                   email,
            password:                password,
            active:                  true,                   # Phantom sig is the auth — account active on-site
            approved:                !requires_approval,
            ip_address:              request.remote_ip,
            registration_ip_address: request.remote_ip,
            trust_level:             ::TrustLevel.levels[:newuser],
          )
          user.password_required!
          user.save!

          # NOTE: deliberately NOT fake-confirming email_tokens. v0.15.2 used
          # `user.email_tokens.update_all(confirmed: true)` here, which is the
          # exact hole this version closes. EmailGate is the new source of
          # truth for whether outbound mail can be sent to this user.

          ::UserCustomField.where(user_id: user.id, name: "user_field_#{field_id}").delete_all
          ::UserCustomField.create!(user_id: user.id, name: "user_field_#{field_id}", value: pubkey)

          ::DiscourseCoinEngine::EmailGate.suppress_user_emails!(
            user,
            reason: email_provided ? :unverified : :no_email
          )
        end
      rescue ::ActiveRecord::RecordInvalid => e
        return render json: { errors: e.record.errors.full_messages }, status: 422
      end

      if user.approved?
        log_on_user(user)
        Rails.logger.info("[coin_engine.auth] phantom signup OK user=#{user.id} username=#{user.username} pubkey=#{pubkey} ip=#{request.remote_ip}")
        render json: {
          ok:       true,
          user:     { id: user.id, username: user.username },
          redirect: '/',
          message:  "Welcome, #{user.username}! Your account is ready.",
        }
      else
        Rails.logger.info("[coin_engine.auth] phantom signup pending-approval user=#{user.id} username=#{user.username} pubkey=#{pubkey}")
        render json: {
          ok:                true,
          user:              { id: user.id, username: user.username },
          requires_approval: true,
          message:           "Account created. An admin needs to approve before you can sign in.",
        }
      end
    rescue RateLimiter::LimitExceeded => e
      render json: { errors: ["Too many signup attempts from this IP. Wait #{e.available_in}s."] }, status: 429
    rescue StandardError => e
      Rails.logger.error("[coin_engine.auth] signup_with_phantom failed: #{e.class}: #{e.message[0,300]}\n#{e.backtrace[0,5].join("\n")}")
      render json: { errors: ['Could not create account. Try again in a moment.'] }, status: 500
    end

    # GET /coin-engine/auth/signin_nonce.json?public_key=<pk>
    # v0.23.0 — Sign-in companion to signup_nonce. Same SIWS pattern, separate
    # Redis namespace so a signup-flow nonce can't be reused to log in (and
    # vice versa).
    def signin_nonce
      pubkey = params[:public_key].to_s.strip
      unless pubkey.match?(SOLANA_PUBKEY_RE)
        return render json: { errors: ['Invalid Solana wallet address.'] }, status: 422
      end

      RateLimiter.new(nil, "phantom_signin_nonce_#{request.remote_ip}", 30, 1.hour).performed!

      nonce  = SecureRandom.hex(16)
      domain = (SiteSetting.force_hostname.presence || ::Discourse.base_url.gsub(%r{^https?://}, '')).to_s
      issued = Time.zone.now.iso8601

      message = <<~MSG.strip
        #{domain} wants you to sign in with your Solana account.

        This signature only proves you control this wallet. It costs no SOL,
        creates no on-chain transaction, and will not appear in your wallet history.

        Action: sign-in
        Nonce: #{nonce}
        Issued: #{issued}
      MSG

      Discourse.redis.setex("coin_engine_signin_nonce:#{pubkey}", NONCE_TTL_SECONDS, message)

      render json: {
        ok:         true,
        nonce:      nonce,
        message:    message,
        expires_in: NONCE_TTL_SECONDS,
      }
    rescue RateLimiter::LimitExceeded => e
      render json: { errors: ["Slow down. Wait #{e.available_in}s."] }, status: 429
    end

    # POST /coin-engine/auth/signin_with_phantom.json
    # Body: { public_key, signature, nonce }
    # v0.23.0 — Verify ed25519 signature against the stored sign-in nonce, look
    # up the user whose wallet UCF matches the pubkey, and log them on. No
    # password required — the wallet signature IS the auth credential.
    def signin_with_phantom
      Rails.logger.info("[coin_engine.auth] signin_with_phantom ip=#{request.remote_ip} ua=#{request.user_agent.to_s[0,120]}")

      if current_user
        return render json: { ok: true, already_logged_in: true, user: { id: current_user.id, username: current_user.username }, redirect: '/' }
      end

      RateLimiter.new(nil, "phantom_signin_#{request.remote_ip}", 10, 1.hour).performed!

      pubkey        = params[:public_key].to_s.strip
      signature_b64 = params[:signature].to_s.strip
      nonce         = params[:nonce].to_s.strip

      unless pubkey.match?(SOLANA_PUBKEY_RE)
        return render json: { errors: ['Invalid Solana wallet address.'] }, status: 422
      end
      if signature_b64.empty? || nonce.empty?
        return render json: { errors: ['Wallet signature missing. Please retry the Phantom sign step.'] }, status: 422
      end

      stored_message = Discourse.redis.get("coin_engine_signin_nonce:#{pubkey}")
      if stored_message.nil?
        return render json: { errors: ['Sign-in challenge expired or never issued. Please retry.'] }, status: 422
      end
      unless stored_message.include?(nonce)
        return render json: { errors: ['Nonce does not match the issued challenge. Please retry.'] }, status: 422
      end
      unless verify_solana_signature(pubkey, stored_message, signature_b64)
        Rails.logger.warn("[coin_engine.auth] signin signature verify FAILED pubkey=#{pubkey} ip=#{request.remote_ip}")
        return render json: { errors: ['Wallet signature did not verify. Please retry the Phantom sign step.'] }, status: 422
      end

      # Burn the nonce immediately so a leaked signature can't be replayed.
      Discourse.redis.del("coin_engine_signin_nonce:#{pubkey}")

      field_id = (SiteSetting.coin_engine_solana_wallet_user_field_id rescue 1).to_i
      ucf = ::UserCustomField.find_by(name: "user_field_#{field_id}", value: pubkey)
      unless ucf
        return render json: { errors: ['No account is linked to that Phantom wallet. Sign up first.'] }, status: 404
      end

      user = ::User.find_by(id: ucf.user_id)
      unless user
        return render json: { errors: ['Linked account is missing. Contact a moderator.'] }, status: 404
      end
      if user.suspended?
        return render json: { errors: ["This account is suspended until #{user.suspended_till&.strftime('%Y-%m-%d')}."] }, status: 403
      end
      unless user.active?
        return render json: { errors: ['This account is inactive. Contact a moderator.'] }, status: 403
      end
      unless user.approved?
        return render json: { errors: ['This account is awaiting admin approval.'] }, status: 403
      end

      log_on_user(user)
      Rails.logger.info("[coin_engine.auth] phantom signin OK user=#{user.id} username=#{user.username} pubkey=#{pubkey} ip=#{request.remote_ip}")

      render json: {
        ok:       true,
        user:     { id: user.id, username: user.username },
        redirect: '/',
        message:  "Welcome back, #{user.username}.",
      }
    rescue RateLimiter::LimitExceeded => e
      render json: { errors: ["Too many sign-in attempts from this IP. Wait #{e.available_in}s."] }, status: 429
    rescue StandardError => e
      Rails.logger.error("[coin_engine.auth] signin_with_phantom failed: #{e.class}: #{e.message[0,300]}\n#{e.backtrace&.first(5)&.join("\n")}")
      render json: { errors: ['Could not sign in. Try again in a moment.'] }, status: 500
    end

    # GET /coin-engine/auth/phantom_taken.json?public_key=<pk>
    # Pre-flight: lets the modal short-circuit before showing the form.
    def phantom_taken
      pubkey = params[:public_key].to_s.strip
      unless pubkey.match?(SOLANA_PUBKEY_RE)
        return render json: { ok: false, taken: false, error: 'invalid_pubkey' }
      end

      field_id = (SiteSetting.coin_engine_solana_wallet_user_field_id rescue 1).to_i
      taken = ::UserCustomField.exists?(name: "user_field_#{field_id}", value: pubkey)
      render json: { ok: true, taken: taken }
    end

    private

    # ed25519 signature verification via Ruby stdlib OpenSSL.
    #
    # Solana pubkeys are 32-byte ed25519 public keys, Base58-encoded.
    # Phantom signs with ed25519 over the UTF-8 bytes of the message; we
    # receive the 64-byte signature as Base64 from the browser.
    #
    # OpenSSL needs a DER-encoded SubjectPublicKeyInfo to consume an
    # ed25519 key — the OID 1.3.101.112 is ed25519 per RFC 8410. We wrap
    # the raw 32-byte pubkey in that structure and hand it to PKey.read.
    # The verify(nil, sig, msg) form (digest = nil) is the ed25519 path
    # — ed25519 hashes the message internally, so we don't pre-digest.
    ED25519_OID = '1.3.101.112'

    def verify_solana_signature(pubkey_b58, message, signature_b64)
      pubkey_bytes = base58_decode(pubkey_b58)
      return false unless pubkey_bytes.bytesize == 32

      signature_bytes = Base64.strict_decode64(signature_b64)
      return false unless signature_bytes.bytesize == 64

      asn1 = ::OpenSSL::ASN1::Sequence.new([
        ::OpenSSL::ASN1::Sequence.new([
          ::OpenSSL::ASN1::ObjectId.new(ED25519_OID),
        ]),
        ::OpenSSL::ASN1::BitString.new(pubkey_bytes),
      ])
      pkey = ::OpenSSL::PKey.read(asn1.to_der)
      pkey.verify(nil, signature_bytes, message.encode(Encoding::UTF_8))
    rescue ::OpenSSL::PKey::PKeyError, ArgumentError, ::ArgumentError => e
      Rails.logger.warn("[coin_engine.auth] verify_solana_signature openssl error: #{e.class}: #{e.message[0,200]}")
      false
    rescue StandardError => e
      Rails.logger.warn("[coin_engine.auth] verify_solana_signature error: #{e.class}: #{e.message[0,200]}")
      false
    end

    # Base58 (Bitcoin alphabet, used by Solana) decode → raw bytes.
    def base58_decode(s)
      num = 0
      s.each_char do |c|
        idx = BASE58_ALPHABET.index(c)
        raise ArgumentError, "invalid base58 char: #{c.inspect}" if idx.nil?
        num = num * 58 + idx
      end
      bytes = []
      while num > 0
        bytes.unshift(num & 0xff)
        num >>= 8
      end
      # Each leading '1' represents a leading zero byte
      leading_ones = 0
      s.each_char { |c| break unless c == '1'; leading_ones += 1 }
      leading_ones.times { bytes.unshift(0) }
      bytes.pack('C*')
    end

    # Activity check: does this wallet have any confirmed transaction in its
    # history? Tri-state so we can distinguish "wallet really has no history"
    # (block) from "RPC didn't answer" (pass-through, fail-open).
    #   :active   — RPC returned >= 1 signature
    #   :inactive — RPC returned an empty array (definitive: no history)
    #   :unknown  — RPC threw / returned nil / returned non-array
    def wallet_activity_state(pubkey)
      result = solana_rpc('getSignaturesForAddress', [pubkey, { 'limit' => 1 }])
      return :unknown if result.nil? || !result.is_a?(Array)
      result.empty? ? :inactive : :active
    end

    # Backward-compat alias if anything else still calls the boolean form.
    def wallet_has_activity?(pubkey)
      wallet_activity_state(pubkey) == :active
    end

    def wallet_balance_lamports(pubkey)
      result = solana_rpc('getBalance', [pubkey])
      result.is_a?(Hash) ? result['value'].to_i : nil
    end

    def solana_rpc(method, params)
      candidates = []
      override = (SiteSetting.coin_engine_solana_rpc_url rescue '').to_s.strip
      candidates << override if override.present?
      PUBLIC_RPC_FALLBACKS.each { |u| candidates << u unless candidates.include?(u) }

      body = { jsonrpc: '2.0', id: 1, method: method, params: params }.to_json
      candidates.each do |url|
        begin
          uri = URI(url)
          req = Net::HTTP::Post.new(uri.request_uri,
                                     'Content-Type' => 'application/json',
                                     'Accept' => 'application/json')
          req.body = body
          res = Net::HTTP.start(uri.host, uri.port,
                                 use_ssl: uri.scheme == 'https',
                                 read_timeout: 8, open_timeout: 5) { |h| h.request(req) }
          parsed = JSON.parse(res.body) rescue nil
          return parsed['result'] if parsed && parsed['result']
        rescue StandardError => e
          Rails.logger.debug("[coin_engine.auth] #{method} via #{url} failed: #{e.class}: #{e.message[0,160]}")
        end
      end
      nil
    end
  end
end
