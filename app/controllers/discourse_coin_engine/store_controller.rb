# frozen_string_literal: true

# v0.12.0 - User-facing store endpoints.
#
# GET    /coin-engine/store/items.json
#   Returns active items (paginated). Anonymous-safe: only public data.
#
# GET    /coin-engine/store/items/:slug.json
#   Single item detail.
#
# POST   /coin-engine/store/purchase_with_reno.json   { item_id }
#   Atomic: validates balance, debits gamification_score, marks paid,
#   queues fulfillment job. Returns the purchase record.
#
# POST   /coin-engine/store/initiate_phantom_purchase.json   { item_id, kind: 'item'|'reno_presale', amount_lamports? }
#   Returns pending purchase record + treasury wallet pubkey + memo string
#   the client uses to construct + sign the SOL transfer in Phantom.
#
# POST   /coin-engine/store/confirm_phantom_purchase.json   { purchase_id, tx_signature }
#   Records the tx_signature; queues a Sidekiq job that verifies on-chain
#   and flips the status to 'paid' once confirmed.
#
# GET    /coin-engine/store/my_purchases.json
#   List the current user's purchases for the FAB "Inventory" tab.

module DiscourseCoinEngine
  class StoreController < ::ApplicationController
    requires_login
    before_action :ensure_logged_in
    skip_before_action :check_xhr, raise: false

    rescue_from ActiveRecord::RecordInvalid do |e|
      render json: { errors: e.record.errors.full_messages }, status: 422
    end

    rescue_from ::Discourse::InvalidParameters do |e|
      render json: { errors: [e.message] }, status: 400
    end

    def items
      Rails.logger.info("[coin_engine.store] items.list user=#{current_user&.id}")
      limit = [params[:limit].to_i, 60].min
      limit = 30 if limit <= 0
      kind = params[:kind].to_s.presence
      scope = StoreItem.active.ordered
      scope = scope.where(kind: kind) if StoreItem::KINDS.include?(kind)
      scope = scope.limit(limit)
      render json: { items: scope.map(&:serialize_for_user) }
    end

    def show
      item = StoreItem.active.find_by(slug: params[:slug])
      raise ::Discourse::NotFound unless item
      render json: { item: item.serialize_for_user }
    end

    # ---------- Buy with $RENO ----------
    def purchase_with_reno
      Rails.logger.info("[coin_engine.store] purchase_with_reno user=#{current_user&.id} item=#{params[:item_id]}")
      RateLimiter.new(current_user, 'coin_engine_store_buy_reno', 30, 1.hour).performed!

      item_id = params[:item_id].to_i
      raise ::Discourse::InvalidParameters, 'item_id' if item_id <= 0

      item = StoreItem.active.find_by(id: item_id)
      raise ::Discourse::NotFound unless item
      return render json: { errors: ['Sold out.'] }, status: 422 if item.sold_out?
      unless item.can_buy_with_reno?
        return render json: { errors: ['This item is not available for $RENO purchase.'] }, status: 422
      end

      price = item.price_reno.to_i
      total = score_for(current_user.id)
      paid  = total_paid_out(current_user.id)
      avail = [total - paid, 0].max
      if avail < price
        return render json: { errors: ["Not enough $RENO. You have #{avail}; this costs #{price}."] }, status: 402
      end

      purchase = nil
      ::ActiveRecord::Base.transaction do
        # Atomic supply decrement (only if not sold out under concurrency)
        if item.supply.to_i > 0
          updated = StoreItem.where(id: item.id).where('supply = 0 OR sold_count < supply').update_all(
            'sold_count = sold_count + 1, updated_at = NOW()',
          )
          raise ActiveRecord::Rollback unless updated == 1
        else
          StoreItem.where(id: item.id).update_all('sold_count = sold_count + 1, updated_at = NOW()')
        end

        # Debit the user via a negative gamification_score row dated today.
        # This routes through the same credit_score helper (negative amount).
        ::DiscourseCoinEngine.credit_score(current_user.id, Date.today, -price)
        # v0.12.1 - bust caches + REFRESH MATERIALIZED VIEW so /leaderboard/N
        # reflects the spend immediately. Without this the user sees their
        # gamification_scores total drop in the FAB but the leaderboard +
        # other endpoints stay stale until the next cache eviction.
        ::DiscourseCoinEngine.refresh_user_score(current_user.id) if ::DiscourseCoinEngine.respond_to?(:refresh_user_score)

        purchase = StorePurchase.create!(
          user_id:         current_user.id,
          item_id:         item.id,
          kind:            'item',
          currency:        'reno',
          amount_paid:     price,
          amount_received: 0,
          wallet_used:     wallet_pubkey_for(current_user),
          status:          'paid',
          paid_at:         Time.zone.now,
        )
      end

      return render json: { errors: ['Sold out.'] }, status: 422 unless purchase

      ::Jobs.enqueue(:coin_engine_fulfill_store_purchase, purchase_id: purchase.id) if defined?(::Jobs::CoinEngineFulfillStorePurchase)

      render json: { ok: true, purchase: purchase.serialize_for_user }
    rescue RateLimiter::LimitExceeded => e
      render json: { errors: ["Slow down. Try again in #{e.available_in}s."] }, status: 429
    end

    # ---------- Buy with SOL via Phantom ----------
    def initiate_phantom_purchase
      Rails.logger.info("[coin_engine.store] initiate_phantom user=#{current_user&.id} kind=#{params[:kind]} item=#{params[:item_id]}")
      RateLimiter.new(current_user, 'coin_engine_store_buy_sol_init', 20, 1.hour).performed!

      kind = params[:kind].to_s
      kind = 'item' unless %w[item reno_presale].include?(kind)

      treasury = SiteSetting.coin_engine_treasury_wallet.to_s.strip rescue ''
      if treasury.empty?
        return render json: { errors: ['Treasury wallet not configured. Contact a moderator.'] }, status: 503
      end

      wallet = wallet_pubkey_for(current_user)
      if wallet.empty?
        return render json: { errors: ['Connect a wallet first (Phantom or BYO).'] }, status: 422
      end

      amount_lamports = 0
      item = nil
      meta = { kind: kind }

      case kind
      when 'item'
        item_id = params[:item_id].to_i
        item = StoreItem.active.find_by(id: item_id)
        raise ::Discourse::NotFound unless item
        return render json: { errors: ['Sold out.'] }, status: 422 if item.sold_out?
        unless item.can_buy_with_sol?
          return render json: { errors: ['This item is not available for SOL purchase.'] }, status: 422
        end
        amount_lamports = item.price_sol_lamports.to_i
        meta[:item_slug] = item.slug
      when 'reno_presale'
        # Buying $RENO at fixed presale rate; client supplies the SOL amount
        amount_lamports = params[:amount_lamports].to_i
        if amount_lamports <= 0 || amount_lamports > (10 * 1_000_000_000)
          raise ::Discourse::InvalidParameters, 'amount_lamports must be 1..10 SOL'
        end
        rate_per_sol = (SiteSetting.coin_engine_presale_reno_per_sol rescue 1_000_000).to_i
        meta[:reno_per_sol] = rate_per_sol
        meta[:expected_reno] = (amount_lamports.to_f / 1_000_000_000.0 * rate_per_sol).to_i
      end

      raise ::Discourse::InvalidParameters, 'amount_lamports' if amount_lamports <= 0

      purchase = StorePurchase.create!(
        user_id:         current_user.id,
        item_id:         item&.id,
        kind:            kind,
        currency:        'sol',
        amount_paid:     amount_lamports,
        amount_received: meta[:expected_reno] || 0,
        wallet_used:     wallet,
        status:          'pending',
        metadata_json:   meta.to_json,
      )

      render json: {
        ok: true,
        purchase:        purchase.serialize_for_user,
        treasury_wallet: treasury,
        memo:            "lf-coin-engine:purchase:#{purchase.id}:user:#{current_user.id}",
        amount_lamports: amount_lamports,
      }
    rescue RateLimiter::LimitExceeded => e
      render json: { errors: ["Slow down. Try again in #{e.available_in}s."] }, status: 429
    end

    def confirm_phantom_purchase
      Rails.logger.info("[coin_engine.store] confirm_phantom user=#{current_user&.id} purchase=#{params[:purchase_id]} sig=#{params[:tx_signature].to_s[0,12]}")
      RateLimiter.new(current_user, 'coin_engine_store_buy_sol_confirm', 30, 1.hour).performed!

      pid = params[:purchase_id].to_i
      sig = params[:tx_signature].to_s.strip
      raise ::Discourse::InvalidParameters, 'purchase_id' if pid <= 0
      raise ::Discourse::InvalidParameters, 'tx_signature' if sig.length < 60 || sig.length > 100

      purchase = StorePurchase.find_by(id: pid, user_id: current_user.id)
      raise ::Discourse::NotFound unless purchase
      return render json: { ok: true, purchase: purchase.serialize_for_user, already: true } unless purchase.pending?

      purchase.update!(tx_signature: sig)
      ::Jobs.enqueue_in(2.seconds, :coin_engine_confirm_phantom_purchase, purchase_id: purchase.id) if defined?(::Jobs::CoinEngineConfirmPhantomPurchase)

      render json: { ok: true, purchase: purchase.serialize_for_user, queued: true }
    rescue RateLimiter::LimitExceeded => e
      render json: { errors: ["Slow down. Try again in #{e.available_in}s."] }, status: 429
    rescue ActiveRecord::RecordNotUnique
      render json: { errors: ['That tx signature is already attached to another purchase.'] }, status: 422
    end

    def my_purchases
      page = [params[:page].to_i, 1].max
      per  = 10
      scope = StorePurchase.where(user_id: current_user.id).recent.limit(per).offset((page - 1) * per)
      total = StorePurchase.where(user_id: current_user.id).count
      render json: {
        purchases: scope.map(&:serialize_for_user),
        page:      page,
        per_page:  per,
        total:     total,
      }
    end

    private

    def score_for(uid)
      ::DiscourseCoinEngine.respond_to?(:coin_user_total) ? ::DiscourseCoinEngine.coin_user_total(uid).to_i : 0
    rescue StandardError
      0
    end

    def total_paid_out(uid)
      sql = "SELECT COALESCE(SUM(amount),0)::bigint FROM coin_engine_payments WHERE user_id = #{uid.to_i} AND status IN ('approved','sent','on_chain')"
      ::ActiveRecord::Base.connection.select_value(sql).to_i
    rescue StandardError
      0
    end

    def wallet_pubkey_for(user)
      field_id = (SiteSetting.coin_engine_solana_wallet_user_field_id rescue 1).to_i
      (user.user_fields || {})[field_id.to_s].to_s.strip
    end
  end
end
