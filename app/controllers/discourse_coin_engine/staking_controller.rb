# frozen_string_literal: true

# v0.12.2 - User staking endpoints. Phantom-signed SOL transfer to the staking
# treasury wallet. Stake records track lock-up duration; admin records the
# return tx when the user unstakes.

module DiscourseCoinEngine
  class StakingController < ::ApplicationController
    requires_login
    before_action :ensure_logged_in
    skip_before_action :check_xhr, raise: false

    rescue_from ActiveRecord::RecordInvalid do |e|
      render json: { errors: e.record.errors.full_messages }, status: 422
    end

    rescue_from ::Discourse::InvalidParameters do |e|
      render json: { errors: [e.message] }, status: 400
    end

    # GET /coin-engine/staking/stakes.json
    def index
      stakes = Stake.for_user(current_user.id).recent.limit(50)
      total_active_lamports = Stake.for_user(current_user.id).active.sum(:amount_lamports).to_i
      render json: {
        stakes: stakes.map(&:serialize_for_user),
        total_active_lamports: total_active_lamports,
        total_active_sol: total_active_lamports.to_f / 1_000_000_000,
      }
    end

    # POST /coin-engine/staking/initiate.json   { amount_lamports, duration_days }
    # Mirrors the store's initiate_phantom_purchase flow. Returns a memo for
    # the client to embed in the SOL transfer instruction.
    def initiate
      RateLimiter.new(current_user, 'coin_engine_stake_init', 10, 1.hour).performed!

      treasury = staking_treasury
      if treasury.empty?
        return render json: { errors: ['Staking treasury not configured. Contact a moderator.'] }, status: 503
      end

      wallet, status_sym = ::DiscourseCoinEngine.user_solana_wallet(current_user)
      case status_sym
      when :unset
        return render json: { errors: ['Connect a Solana wallet first.'] }, status: 422
      when :malformed
        return render json: {
          errors: ["Your linked wallet is not a valid Solana address (#{wallet.length} chars, must be 32-44 Base58). Re-link via Preferences."]
        }, status: 422
      end

      amount = params[:amount_lamports].to_i
      duration = params[:duration_days].to_i
      duration = 30 if duration <= 0
      raise ::Discourse::InvalidParameters, 'amount_lamports must be 0.01-100 SOL' if amount < 10_000_000 || amount > 100 * 1_000_000_000
      raise ::Discourse::InvalidParameters, 'duration_days must be 1-365' if duration < 1 || duration > 365

      Rails.logger.info("[coin_engine.staking] initiate user=#{current_user.id} amount=#{amount} duration=#{duration}")

      stake = Stake.create!(
        user_id:         current_user.id,
        amount_lamports: amount,
        wallet_address:  wallet,
        status:          'pending',
        duration_days:   duration,
        locked_until:    duration.days.from_now,
      )

      render json: {
        ok:               true,
        stake:            stake.serialize_for_user,
        treasury_wallet:  treasury,
        memo:             "lf-coin-engine:stake:#{stake.id}:user:#{current_user.id}",
        amount_lamports:  amount,
      }
    rescue RateLimiter::LimitExceeded => e
      render json: { errors: ["Slow down. Try again in #{e.available_in}s."] }, status: 429
    end

    # POST /coin-engine/staking/confirm.json   { stake_id, tx_signature }
    def confirm
      RateLimiter.new(current_user, 'coin_engine_stake_confirm', 30, 1.hour).performed!

      sid = params[:stake_id].to_i
      sig = params[:tx_signature].to_s.strip
      raise ::Discourse::InvalidParameters, 'stake_id' if sid <= 0
      raise ::Discourse::InvalidParameters, 'tx_signature' if sig.length < 60 || sig.length > 100

      stake = Stake.find_by(id: sid, user_id: current_user.id)
      raise ::Discourse::NotFound unless stake
      return render json: { ok: true, stake: stake.serialize_for_user, already: true } unless stake.status == 'pending'

      Rails.logger.info("[coin_engine.staking] confirm user=#{current_user.id} stake=#{sid} sig=#{sig[0,12]}")

      stake.update!(stake_tx: sig)
      ::Jobs.enqueue_in(2.seconds, :coin_engine_confirm_stake, stake_id: stake.id) if defined?(::Jobs::CoinEngineConfirmStake)

      render json: { ok: true, stake: stake.serialize_for_user, queued: true }
    rescue RateLimiter::LimitExceeded => e
      render json: { errors: ["Slow down. Try again in #{e.available_in}s."] }, status: 429
    rescue ActiveRecord::RecordNotUnique
      render json: { errors: ['That tx signature is already attached to another stake.'] }, status: 422
    end

    # POST /coin-engine/staking/unstake_request.json   { stake_id }
    # Mark a stake as unstaking once it's past the locked_until date.
    # Admin processes the actual on-chain return separately.
    def unstake_request
      RateLimiter.new(current_user, 'coin_engine_stake_unstake', 5, 1.hour).performed!

      stake = Stake.find_by(id: params[:stake_id].to_i, user_id: current_user.id)
      raise ::Discourse::NotFound unless stake
      return render json: { errors: ["Not yet unlockable. #{stake.days_until_unlock} days left."] }, status: 422 unless stake.unlockable?
      return render json: { errors: ['Stake not in active state.'] }, status: 422 unless stake.status == 'active'

      stake.update!(status: 'unstaking')
      Rails.logger.info("[coin_engine.staking] unstake_request user=#{current_user.id} stake=#{stake.id}")
      dm_admins_unstake(stake)
      render json: { ok: true, stake: stake.serialize_for_user }
    rescue RateLimiter::LimitExceeded => e
      render json: { errors: ["Slow down. Try again in #{e.available_in}s."] }, status: 429
    end

    private

    def staking_treasury
      # Falls back to the regular treasury wallet if no separate staking treasury
      # is configured. Admin can set coin_engine_staking_treasury to use a
      # dedicated cold wallet for stake principal.
      st = (SiteSetting.coin_engine_staking_treasury rescue '').to_s.strip
      return st unless st.empty?
      (SiteSetting.coin_engine_treasury_wallet rescue '').to_s.strip
    end

    def wallet_for(user)
      field_id = (SiteSetting.coin_engine_solana_wallet_user_field_id rescue 1).to_i
      (user.user_fields || {})[field_id.to_s].to_s.strip
    end

    def dm_admins_unstake(stake)
      target = ::User.find_by(id: stake.user_id)
      return unless target
      admins = ::User.where(admin: true).where('id <> ?', ::Discourse.system_user.id).limit(5)
      return if admins.empty?
      raw = <<~MD.strip
        @#{target.username} requested an unstake.

        - Stake ##{stake.id}
        - Amount: **#{stake.amount_sol.round(4)} SOL** (#{stake.amount_lamports} lamports)
        - Wallet: `#{stake.wallet_address}`
        - Locked since: #{stake.created_at.strftime('%Y-%m-%d')}
        - Duration: #{stake.duration_days}d (eligible since #{stake.locked_until&.strftime('%Y-%m-%d')})
        - Stake tx: `#{stake.stake_tx}`

        Send the SOL back to their wallet, then mark the stake completed in the admin panel with the return tx signature.
      MD
      ::PostCreator.create!(
        ::Discourse.system_user,
        title: "Unstake request from @#{target.username} (stake ##{stake.id})",
        raw: raw,
        archetype: ::Archetype.private_message,
        target_usernames: admins.pluck(:username).join(','),
        skip_validations: true,
      )
    rescue StandardError => e
      Rails.logger.error("[coin_engine.staking] DM admins failed: #{e.message}")
    end
  end
end
