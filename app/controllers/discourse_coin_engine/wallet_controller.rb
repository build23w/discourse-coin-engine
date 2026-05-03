# frozen_string_literal: true

module DiscourseCoinEngine
  class WalletController < ::ApplicationController
    requires_login
    before_action :ensure_logged_in
    skip_before_action :check_xhr, raise: false

    rescue_from ActiveRecord::RecordInvalid do |e|
      render json: { errors: e.record.errors.full_messages }, status: 422
    end

    rescue_from ::Discourse::InvalidParameters do |e|
      render json: { errors: [e.message] }, status: 400
    end

    def seed
      Rails.logger.info("[coin_engine.wallet] seed start user=#{current_user&.id}")
      params.require(:public_key)
      params.require(:secret_key)

      pubkey = params[:public_key].to_s.strip
      seckey = params[:secret_key]
      raise ::Discourse::InvalidParameters, 'public_key' if pubkey.length < 32 || pubkey.length > 64

      bytes = decode_secret_key(seckey)
      raise ::Discourse::InvalidParameters, 'secret_key must decode to 64 bytes' if bytes.bytesize != 64

      if CustodialWallet.exists?(user_id: current_user.id, revoked_at: nil)
        return render json: { errors: ['Custodial wallet already exists'] }, status: 422
      end

      field_id  = (SiteSetting.coin_engine_solana_wallet_user_field_id rescue 1).to_i
      existing  = (current_user.user_fields || {})[field_id.to_s].to_s.strip
      if !existing.empty? && existing != pubkey
        return render json: { errors: ['Wallet field already populated'] }, status: 422
      end

      unless WalletEncryption.passphrase_set?
        return render json: { errors: ['Server custodial wallets are not configured'] }, status: 503
      end

      enc = WalletEncryption.encrypt!(bytes)
      CustodialWallet.create!(
        user_id:          current_user.id,
        public_key:       pubkey,
        encrypted_secret: enc[:encrypted_secret],
        iv:               enc[:iv],
        auth_tag:         enc[:auth_tag],
        salt:             enc[:salt],
        source:           'signup_browser',
      )

      ::UserCustomField.upsert(
        { user_id: current_user.id, name: "user_field_#{field_id}", value: pubkey,
          created_at: Time.zone.now, updated_at: Time.zone.now },
        unique_by: [:user_id, :name],
      )

      render json: { ok: true, public_key: pubkey }
    rescue ActiveRecord::RecordNotUnique
      render json: { errors: ['Custodial wallet already exists'] }, status: 422
    end

    def export
      Rails.logger.info("[coin_engine.wallet] export start user=#{current_user&.id}")
      RateLimiter.new(current_user, 'coin_engine_wallet_export', 3, 24.hours).performed!

      cw = CustodialWallet.find_by(user_id: current_user.id, revoked_at: nil)
      return render json: { errors: ['No custodial wallet on file. You appear to have brought your own wallet.'] }, status: 404 unless cw

      unless WalletEncryption.passphrase_set?
        return render json: { errors: ['Encryption key not configured on server. Contact a moderator.'] }, status: 503
      end

      begin
        plaintext = WalletEncryption.decrypt!(cw)
      rescue WalletEncryption::DecryptFailed => e
        Rails.logger.error("[coin_engine] decrypt failed for user #{current_user.id}: #{e.message}")
        return render json: { errors: ['Decryption failed. Contact a moderator.'] }, status: 500
      end

      cw.mark_exported!

      payload = {
        format:     'solana-keypair-array',
        publicKey:  cw.public_key,
        secretKey:  plaintext.bytes,
        username:   current_user.username,
        exportedAt: Time.zone.now.iso8601,
        warning:    'Keep this file secret. Anyone with these bytes controls your wallet.',
      }

      filename = "wallet-#{current_user.username}-#{Time.zone.now.strftime('%Y%m%d')}.json"
      response.headers['Content-Disposition'] = %(attachment; filename="#{filename}")
      render json: payload
    rescue RateLimiter::LimitExceeded => e
      render json: { errors: ["Export limit reached. Try again in #{(e.available_in / 3600.0).round(1)}h."] }, status: 429
    end

    def withdraw_request_create
      Rails.logger.info("[coin_engine.wallet] withdraw_request_create user=#{current_user&.id}")
      RateLimiter.new(current_user, 'coin_engine_withdraw_request', 1, 48.hours).performed!

      field_id = (SiteSetting.coin_engine_solana_wallet_user_field_id rescue 1).to_i
      wallet = (current_user.user_fields || {})[field_id.to_s].to_s.strip
      return render json: { errors: ['Set your Solana wallet first.'] }, status: 422 if wallet.empty?

      threshold    = (SiteSetting.coin_engine_solana_min_send_threshold rescue 20_000).to_i
      withdrawable = available_to_withdraw(current_user.id)
      amount       = withdrawable

      if WithdrawRequest.exists?(user_id: current_user.id, status: 'pending')
        return render json: { errors: ['You already have a pending withdraw request.'] }, status: 422
      end

      note = params[:user_note].to_s.strip[0, 1000]

      wr = WithdrawRequest.create!(
        user_id:        current_user.id,
        amount:         amount,
        status:         'pending',
        wallet_address: wallet,
        user_note:      note.presence,
      )

      dm_admins(wr, threshold)

      render json: { ok: true, request: serialize_request(wr) }
    rescue RateLimiter::LimitExceeded => e
      render json: { errors: ["Please wait #{(e.available_in / 3600.0).round(1)}h before requesting again."] }, status: 429
    end

    def withdraw_request_destroy
      wr = WithdrawRequest.find_by(user_id: current_user.id, status: 'pending')
      return render json: { errors: ['No pending request to cancel.'] }, status: 404 unless wr
      wr.update!(status: 'cancelled', decided_at: Time.zone.now, decided_by_user_id: current_user.id)
      render json: { ok: true }
    end

    def withdraw_request_show
      wr = WithdrawRequest.where(user_id: current_user.id).order(created_at: :desc).first
      return render json: { request: nil } unless wr
      render json: { request: serialize_request(wr) }
    end

    def status
      uid = current_user.id
      Rails.logger.info("[coin_engine.wallet] status user=#{uid}")
      field_id = (SiteSetting.coin_engine_solana_wallet_user_field_id rescue 1).to_i
      wallet_pubkey = (current_user.user_fields || {})[field_id.to_s].to_s.strip
      cust = CustodialWallet.find_by(user_id: uid, revoked_at: nil)

      total = (::DiscourseCoinEngine.respond_to?(:coin_user_total) ? ::DiscourseCoinEngine.coin_user_total(uid).to_i : 0) rescue 0
      paid = begin
        paid_sql = "SELECT COALESCE(SUM(amount),0)::bigint FROM coin_engine_payments WHERE user_id = #{uid.to_i} AND status IN ('approved','sent','on_chain')"
        ::ActiveRecord::Base.connection.select_value(paid_sql).to_i
      rescue StandardError
        0
      end
      avail = [total - paid, 0].max

      pending_wr = WithdrawRequest.where(user_id: uid, status: 'pending').order(created_at: :desc).first

      autogen_enabled = (SiteSetting.coin_engine_wallet_autogen_enabled rescue false)
      threshold       = (SiteSetting.coin_engine_solana_min_send_threshold rescue 20_000).to_i

      # is_phantom = the linked wallet is something OTHER than the custodial one
      # we hold (covers BYO-from-day-one OR custodial user who connected Phantom).
      # fallback_pubkey = the custodial pubkey we'd swap back to on disconnect.
      is_phantom = cust && !wallet_pubkey.empty? && wallet_pubkey != cust.public_key

      render json: {
        wallet: {
          linked:           !wallet_pubkey.empty?,
          custodial:        !!cust,
          self_custody:     !wallet_pubkey.empty? && cust.nil?,
          public_key:       wallet_pubkey.presence,
          source:           cust&.source,
          exported_at:      cust&.exported_at,
          is_phantom:       !!is_phantom,
          fallback_pubkey:  cust&.public_key,
        },
        balance: {
          total:     total,
          paid:      paid,
          available: avail,
        },
        autogen: {
          enabled:   !!autogen_enabled,
          available: WalletEncryption.passphrase_set? && !!autogen_enabled,
        },
        withdraw_threshold: threshold,
        pending_request:    pending_wr ? serialize_request(pending_wr) : nil,
      }
    end

    def request_generation
      Rails.logger.info("[coin_engine.wallet] request_generation user=#{current_user&.id}")
      RateLimiter.new(current_user, 'coin_engine_request_wallet_gen', 1, 5.minutes).performed!

      unless WalletEncryption.passphrase_set?
        return render json: { errors: ['Server custodial wallets are not configured. Bring your own wallet via Preferences.'] }, status: 503
      end
      autogen = (SiteSetting.coin_engine_wallet_autogen_enabled rescue false)
      unless autogen
        return render json: { errors: ['Auto-generation is disabled. Bring your own wallet via Preferences.'] }, status: 503
      end

      field_id = (SiteSetting.coin_engine_solana_wallet_user_field_id rescue 1).to_i
      existing = (current_user.user_fields || {})[field_id.to_s].to_s.strip
      if !existing.empty?
        return render json: { errors: ['You already have a wallet linked.'] }, status: 422
      end
      if CustodialWallet.exists?(user_id: current_user.id, revoked_at: nil)
        return render json: { errors: ['A custodial wallet already exists for your account.'] }, status: 422
      end

      ::Jobs.enqueue(:coin_engine_generate_wallet, user_id: current_user.id, source: 'self_service')
      render json: { ok: true, queued: true }
    rescue RateLimiter::LimitExceeded => e
      render json: { errors: ["Please wait #{e.available_in}s and try again."] }, status: 429
    end

    # POST /coin-engine/wallet/connect_phantom.json
    # User clicks "Connect Phantom" in the FAB. Browser called
    # window.solana.connect() and got a public key; it POSTs the key here.
    # We validate format and overwrite user_field 1. The custodial row is
    # left untouched as the "fallback" — disconnect restores it.
    def connect_phantom
      Rails.logger.info("[coin_engine.wallet] connect_phantom user=#{current_user&.id}")
      RateLimiter.new(current_user, 'coin_engine_phantom_connect', 10, 1.hour).performed!

      pubkey = params[:public_key].to_s.strip
      raise ::Discourse::InvalidParameters, 'public_key' if pubkey.length < 32 || pubkey.length > 64
      raise ::Discourse::InvalidParameters, 'public_key (base58 only)' unless pubkey =~ %r{\A[1-9A-HJ-NP-Za-km-z]+\z}

      field_id = (SiteSetting.coin_engine_solana_wallet_user_field_id rescue 1).to_i

      ::UserCustomField.upsert(
        { user_id: current_user.id, name: "user_field_#{field_id}", value: pubkey,
          created_at: Time.zone.now, updated_at: Time.zone.now },
        unique_by: [:user_id, :name],
      )

      # Bust the user serializer cache so /u/{username}.json reflects the swap
      begin
        ::User.where(id: current_user.id).update_all(updated_at: Time.zone.now)
        Rails.cache.delete("coin_engine_score_user_#{current_user.id}")
      rescue StandardError
      end

      Rails.logger.info("[coin_engine] phantom connected for user #{current_user.id} pubkey=#{pubkey}")
      render json: { ok: true, public_key: pubkey, fallback_available: CustodialWallet.exists?(user_id: current_user.id, revoked_at: nil) }
    rescue RateLimiter::LimitExceeded => e
      render json: { errors: ["Too many connection attempts. Wait #{e.available_in}s."] }, status: 429
    end

    # POST /coin-engine/wallet/disconnect_phantom.json
    # Restore user_field 1 to the custodial public key (the fallback).
    # No-op + error if the user doesn't have a custodial wallet to fall back on.
    def disconnect_phantom
      Rails.logger.info("[coin_engine.wallet] disconnect_phantom user=#{current_user&.id}")
      cust = CustodialWallet.find_by(user_id: current_user.id, revoked_at: nil)
      return render json: { errors: ['No custodial wallet on file to fall back to. Set a wallet via Preferences instead.'] }, status: 422 unless cust

      field_id = (SiteSetting.coin_engine_solana_wallet_user_field_id rescue 1).to_i
      ::UserCustomField.upsert(
        { user_id: current_user.id, name: "user_field_#{field_id}", value: cust.public_key,
          created_at: Time.zone.now, updated_at: Time.zone.now },
        unique_by: [:user_id, :name],
      )

      begin
        ::User.where(id: current_user.id).update_all(updated_at: Time.zone.now)
        Rails.cache.delete("coin_engine_score_user_#{current_user.id}")
      rescue StandardError
      end

      Rails.logger.info("[coin_engine] phantom disconnected for user #{current_user.id}, fell back to custodial #{cust.public_key}")
      render json: { ok: true, public_key: cust.public_key }
    end

    private

    def decode_secret_key(seckey)
      if seckey.is_a?(Array)
        seckey.pack('C*')
      elsif seckey.is_a?(String)
        begin
          decoded = Base64.strict_decode64(seckey)
          return decoded if decoded.bytesize == 64
        rescue ArgumentError
        end
        if seckey.include?(',')
          ints = seckey.split(',').map { |s| s.strip.to_i }
          return ints.pack('C*') if ints.length == 64
        end
        ''
      else
        ''
      end
    end

    def available_to_withdraw(user_id)
      total = (::DiscourseCoinEngine.respond_to?(:coin_user_total) ? ::DiscourseCoinEngine.coin_user_total(user_id).to_i : 0) rescue 0
      paid_sql = "SELECT COALESCE(SUM(amount),0)::bigint FROM coin_engine_payments WHERE user_id = #{user_id.to_i} AND status IN ('approved','sent','on_chain')"
      paid = ::ActiveRecord::Base.connection.select_value(paid_sql).to_i
      [total - paid, 0].max
    rescue StandardError => e
      Rails.logger.error("[coin_engine] available_to_withdraw failed: #{e.message}")
      0
    end

    def dm_admins(wr, threshold)
      target_username = ::User.find_by(id: wr.user_id)&.username || '?'
      admins = ::User.where(admin: true).where('id <> ?', ::Discourse.system_user.id).limit(5)
      return if admins.empty?

      raw = <<~MD.strip
        @#{target_username} requested a manual $RENO withdraw.

        - Amount: **#{wr.amount.to_s.reverse.gsub(/...(?=.)/, '\&,').reverse} $RENO**
        - Wallet: `#{wr.wallet_address}`
        - Threshold: #{threshold} (auto-payout floor)
        - Note: #{wr.user_note.presence || '_(none)_'}

        Approve / reject in [Admin → Coin Engine → Withdraw Requests](/admin/coin-engine).
      MD

      ::PostCreator.create!(
        ::Discourse.system_user,
        title: "Withdraw request from @#{target_username} (##{wr.id})",
        raw: raw,
        archetype: ::Archetype.private_message,
        target_usernames: admins.pluck(:username).join(','),
        skip_validations: true,
      )
    rescue StandardError => e
      Rails.logger.error("[coin_engine] withdraw DM failed: #{e.message}")
    end

    def serialize_request(wr)
      {
        id:             wr.id,
        amount:         wr.amount,
        status:         wr.status,
        wallet_address: wr.wallet_address,
        user_note:      wr.user_note,
        admin_note:     wr.admin_note,
        created_at:     wr.created_at,
        decided_at:     wr.decided_at,
      }
    end
  end
end
