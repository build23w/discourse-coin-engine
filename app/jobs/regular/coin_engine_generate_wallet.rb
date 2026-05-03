# frozen_string_literal: true

# v0.11.0 — Sidekiq job that generates a custodial Solana wallet for a user.
# Idempotent: if the user already has a row in coin_engine_custodial_wallets OR
# a non-empty wallet user_field, the job no-ops.
#
# Triggered by:
#   - DiscourseEvent.on(:user_created) for new signups (when the browser
#     didn't already submit a client-generated keypair)
#   - Admin "Backfill missing wallets" button
#   - Admin "Regenerate wallet" per-user action

module Jobs
  class CoinEngineGenerateWallet < ::Jobs::Base
    sidekiq_options retry: 2

    def execute(args)
      user_id = args[:user_id].to_i
      return if user_id <= 0

      user = ::User.find_by(id: user_id)
      return unless user

      # Encryption passphrase must be configured before we generate anything.
      unless ::DiscourseCoinEngine::WalletEncryption.passphrase_set?
        Rails.logger.warn("[coin_engine] generate_wallet skipped for user #{user_id}: encryption passphrase not set")
        return
      end

      field_id = (SiteSetting.coin_engine_solana_wallet_user_field_id rescue 1).to_i
      existing_wallet = (user.user_fields || {})[field_id.to_s].to_s.strip

      # Already has a wallet (BYO or previously custodied) — skip
      if !existing_wallet.empty? && ::DiscourseCoinEngine::CustodialWallet.exists?(user_id: user_id, revoked_at: nil)
        return
      end

      # User has a wallet but no custodial record — they're self-custodied. Skip.
      return if !existing_wallet.empty? && !::DiscourseCoinEngine::CustodialWallet.exists?(user_id: user_id)

      # Already has a custodial row but lost the user_field — heal the field
      if (cust = ::DiscourseCoinEngine::CustodialWallet.find_by(user_id: user_id, revoked_at: nil))
        write_wallet_to_user_field(user, field_id, cust.public_key)
        return
      end

      # Generate fresh
      kp = ::DiscourseCoinEngine::WalletGenerator.generate
      enc = ::DiscourseCoinEngine::WalletEncryption.encrypt!(kp[:secret_key])

      ::DiscourseCoinEngine::CustodialWallet.create!(
        user_id:          user_id,
        public_key:       kp[:public_key],
        encrypted_secret: enc[:encrypted_secret],
        iv:               enc[:iv],
        auth_tag:         enc[:auth_tag],
        salt:             enc[:salt],
        source:           args[:source].to_s.presence || 'backfill_server',
      )

      write_wallet_to_user_field(user, field_id, kp[:public_key])
      Rails.logger.info("[coin_engine] generated custodial wallet for user #{user_id} pubkey=#{kp[:public_key]}")
    rescue ::DiscourseCoinEngine::WalletEncryption::PassphraseMissing => e
      Rails.logger.warn("[coin_engine] #{e.message}")
    rescue ActiveRecord::RecordNotUnique
      # Race with another worker — that's fine, the existing row wins
      Rails.logger.info("[coin_engine] generate_wallet: existing custodial row for user #{user_id}, no-op")
    rescue StandardError => e
      Rails.logger.error("[coin_engine] generate_wallet failed for user #{user_id}: #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
    end

    private

    def write_wallet_to_user_field(user, field_id, pubkey)
      ::UserCustomField.upsert(
        { user_id: user.id, name: "user_field_#{field_id}", value: pubkey, created_at: Time.zone.now, updated_at: Time.zone.now },
        unique_by: [:user_id, :name]
      )
    rescue StandardError => e
      Rails.logger.error("[coin_engine] failed to write wallet to user_field for #{user.id}: #{e.message}")
    end
  end
end
