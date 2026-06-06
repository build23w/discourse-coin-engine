# frozen_string_literal: true

# Phase 2 — Economy: Tips, Shop, Bounties, Stakes.
# Mounted under /coin-engine/economy/* — see plugin.rb routes.
module DiscourseCoinEngine
  class EconomyController < ::ApplicationController
    requires_login except: [:shop_index]

    # Surface real exceptions to the client as JSON so we don't lose them in a
    # generic 500. Lets the FAB toast show the actual error class + message
    # instead of the user having to grep production.log.

    # ===== Tips =====
    # POST /coin-engine/economy/tips.json { recipient_username, amount, post_id?, note? }
    def create_tip
      RateLimiter.new(current_user, 'ce_tip_create', 30, 1.hour).performed!
      raise Discourse::InvalidAccess unless current_user
      recipient = ::User.find_by(username_lower: params[:recipient_username].to_s.downcase)
      return render_json_error('recipient not found', status: 404) unless recipient
      amount = params[:amount].to_i
      return render_json_error('amount must be positive') if amount <= 0
      return render_json_error('cannot tip yourself') if recipient.id == current_user.id
      sender_balance = ::DiscourseCoinEngine.coin_user_total(current_user.id)
      return render_json_error('insufficient balance', status: 422) if sender_balance < amount

      # v0.10.2 — enforce the existing tip_max_per_day setting (was defined but unused).
      # Counts $RENO tipped in the last 24h, refuses if this tip would push over.
      max_per_day = (SiteSetting.coin_engine_tip_max_per_day rescue 1000).to_i
      if max_per_day > 0
        sent_today = Tip.where(sender_user_id: current_user.id).where('created_at > ?', 24.hours.ago).sum(:amount).to_i
        if sent_today + amount > max_per_day
          return render_json_error("Daily tip cap reached (#{max_per_day} #{SiteSetting.coin_engine_coin_name}). Already tipped #{sent_today} in last 24h.", status: 429)
        end
      end
      # Min amount enforcement (also already a setting but never checked).
      min_amount = (SiteSetting.coin_engine_tip_min_amount rescue 10).to_i
      return render_json_error("Minimum tip is #{min_amount}", status: 422) if amount < min_amount

      tip = nil
      ActiveRecord::Base.transaction do
        # Debit sender, credit recipient via gamification_scores rows.
        ts = Date.today
        ::DiscourseCoinEngine.credit_score(current_user.id, ts, -amount)
        ::DiscourseCoinEngine.credit_score(recipient.id, ts, amount)
        tip = Tip.create!(
          sender_user_id: current_user.id,
          recipient_user_id: recipient.id,
          post_id: params[:post_id].presence,
          amount: amount,
          note: params[:note].to_s[0, 280],
          status: 'sent',
        )
        ::DiscourseCoinEngine.refresh_user_score(current_user.id)
        ::DiscourseCoinEngine.refresh_user_score(recipient.id)
      end

      # v0.8.4 — instant push + PM (out-of-transaction so a notification
      # failure never rolls back the credit).
      begin
        ::DiscourseCoinEngine::Notifier.credit!(
          recipient: recipient,
          amount:    amount,
          reason:    'tip',
          sender:    current_user,
          note:      params[:note].to_s[0, 280].presence,
          ref:       { type: 'tip', id: tip.id, post_id: tip.post_id },
        )
      rescue StandardError => e
        Rails.logger.warn("[coin_engine] tip notify failed: #{e.class}: #{e.message}")
      end

      render json: { id: tip.id, amount: amount, recipient: recipient.username, status: 'sent' }
    rescue ActiveRecord::RecordInvalid => e
      render_json_error(e.record.errors.full_messages.join(', '))
    end

    # GET /coin-engine/economy/tips/sent.json
    def list_sent_tips
      tips = Tip.where(sender_user_id: current_user.id).order(created_at: :desc).limit(50)
      render json: { tips: tips.map { |t| serialize_tip(t) } }
    end

    # GET /coin-engine/economy/tips/received.json
    def list_received_tips
      tips = Tip.where(recipient_user_id: current_user.id).order(created_at: :desc).limit(50)
      render json: { tips: tips.map { |t| serialize_tip(t) } }
    end

    # ===== Shop =====
    # GET /coin-engine/economy/shop.json (anonymous)
    def shop_index
      items = ShopItem.enabled.order(:sort_order, :id).limit(100)
      render json: { items: items.map { |i| serialize_shop_item(i) } }
    end

    # POST /coin-engine/economy/shop/:slug/redeem.json
    def redeem_shop_item
      RateLimiter.new(current_user, 'ce_shop_redeem', 20, 1.day).performed!
      item = ShopItem.enabled.find_by(slug: params[:slug])
      return render_json_error('item not found', status: 404) unless item
      return render_json_error('out of stock', status: 422) unless item.in_stock?
      bal = ::DiscourseCoinEngine.coin_user_total(current_user.id)
      return render_json_error('insufficient balance', status: 422) if bal < item.price

      red = nil
      ActiveRecord::Base.transaction do
        ::DiscourseCoinEngine.credit_score(current_user.id, Date.today, -item.price)
        red = Redemption.create!(
          user_id: current_user.id,
          shop_item_id: item.id,
          price_paid: item.price,
          payload: item.payload,
          status: 'active',
        )
        item.decrement!(:stock) if item.stock > 0
        ::DiscourseCoinEngine.refresh_user_score(current_user.id)
      end
      render json: { redemption_id: red.id, item: item.slug, expires_at: red.expires_at }
    end

    # GET /coin-engine/economy/redemptions.json
    def list_redemptions
      reds = Redemption.where(user_id: current_user.id).order(created_at: :desc).limit(50)
      render json: { redemptions: reds.map { |r| { id: r.id, item_slug: r.shop_item&.slug, status: r.status, expires_at: r.expires_at, price_paid: r.price_paid } } }
    end

    # ===== Bounties =====
    # POST /coin-engine/economy/bounties.json
    #   { topic_id, post_id?, amount, note?, expires_in_days?,
    #     bounty_type? (manual|random_reach), max_winners?, invite_count?, window_minutes? }
    def create_bounty
      RateLimiter.new(current_user, 'ce_bounty_create', 10, 1.day).performed!
      amount = params[:amount].to_i
      return render_json_error('amount must be positive') if amount <= 0
      bal = ::DiscourseCoinEngine.coin_user_total(current_user.id)
      return render_json_error('insufficient balance', status: 422) if bal < amount

      topic = ::Topic.find_by(id: params[:topic_id])
      return render_json_error('topic not found', status: 404) unless topic
      expires_in = (params[:expires_in_days].presence || 7).to_i.clamp(1, 30)

      # v0.10.0 — random_reach config
      bounty_type    = (params[:bounty_type].presence || 'manual').to_s
      bounty_type    = 'manual' unless %w[manual random_reach].include?(bounty_type)
      max_winners    = (params[:max_winners].presence || 1).to_i.clamp(1, 50)
      invite_count   = (params[:invite_count].presence || 5).to_i.clamp(2, 50)
      window_minutes = (params[:window_minutes].presence || 30).to_i.clamp(5, 1440)

      bounty = nil
      ActiveRecord::Base.transaction do
        ::DiscourseCoinEngine.credit_score(current_user.id, Date.today, -amount)
        bounty = Bounty.create!(
          poster_user_id: current_user.id,
          topic_id: topic.id,
          post_id: params[:post_id].presence,
          amount: amount,
          status: 'open',
          expires_at: expires_in.days.from_now,
          note: params[:note].to_s[0, 1000],
          bounty_type: bounty_type,
          max_winners: max_winners,
          invite_count: invite_count,
          window_minutes: window_minutes,
        )
        ::DiscourseCoinEngine.refresh_user_score(current_user.id)
      end

      # If random_reach, kick off round 1 (DM + MessageBus to invitees, schedule expiry job)
      if bounty.bounty_type == 'random_reach'
        begin
          ::DiscourseCoinEngine::BountyDispatcher.dispatch_round!(bounty)
        rescue StandardError => e
          Rails.logger.warn("[coin_engine] dispatch_round! failed for bounty #{bounty.id}: #{e.message}")
        end
      end

      render json: {
        id: bounty.id, amount: amount, expires_at: bounty.expires_at,
        bounty_type: bounty.bounty_type, max_winners: bounty.max_winners,
        invite_count: bounty.invite_count, window_minutes: bounty.window_minutes
      }
    end

    # v0.10.0 — POST /coin-engine/economy/bounties/:id/claim.json
    # Explicit claim endpoint for random_reach bounties. Also auto-fires from
    # the post_created DiscourseEvent hook in plugin.rb when an invited user
    # posts a reply on the bounty topic.
    def claim_bounty
      RateLimiter.new(current_user, 'ce_bounty_claim', 30, 1.hour).performed!
      bounty = Bounty.find_by(id: params[:id])
      return render_json_error('bounty not found', status: 404) unless bounty
      result = ::DiscourseCoinEngine::BountyDispatcher.attempt_claim!(bounty, current_user, nil)
      render json: result, status: (result[:ok] ? 200 : 422)
    end

    # POST /coin-engine/economy/bounties/:id/award.json { winning_post_id }
    def award_bounty
      RateLimiter.new(current_user, 'ce_bounty_award', 30, 1.hour).performed!
      bounty = Bounty.find_by(id: params[:id])
      return render_json_error('bounty not found', status: 404) unless bounty
      return render_json_error('only the poster can award', status: 403) unless bounty.poster_user_id == current_user.id
      return render_json_error('bounty is not open', status: 422) unless bounty.open?
      post = ::Post.find_by(id: params[:winning_post_id])
      return render_json_error('post not found', status: 404) unless post
      winner = ::User.find_by(id: post.user_id)
      return render_json_error('winner not found', status: 404) unless winner

      ActiveRecord::Base.transaction do
        ::DiscourseCoinEngine.credit_score(winner.id, Date.today, bounty.amount)
        bounty.update!(status: 'awarded', winner_user_id: winner.id, winning_post_id: post.id, awarded_at: Time.now)
        ::DiscourseCoinEngine.refresh_user_score(winner.id)
      end

      # v0.8.4 — push + PM the winner.
      begin
        ::DiscourseCoinEngine::Notifier.credit!(
          recipient: winner,
          amount:    bounty.amount,
          reason:    'bounty_award',
          sender:    current_user,
          note:      bounty.title.to_s[0, 280].presence,
          ref:       { type: 'bounty', id: bounty.id, post_id: post.id },
        )
      rescue StandardError => e
        Rails.logger.warn("[coin_engine] bounty notify failed: #{e.class}: #{e.message}")
      end

      render json: { id: bounty.id, status: 'awarded', winner: winner.username }
    end

    # GET /coin-engine/economy/bounties.json
    def list_bounties
      open_b = Bounty.open.order(created_at: :desc).limit(50)
      render json: { bounties: open_b.map { |b| serialize_bounty(b) } }
    end

    # ===== Stakes =====
    # POST /coin-engine/economy/stakes.json { amount, duration_days }
    def create_stake
      RateLimiter.new(current_user, 'ce_stake_create', 20, 1.day).performed!
      amount = params[:amount].to_i
      duration = params[:duration_days].to_i
      return render_json_error('amount must be positive') if amount <= 0
      return render_json_error('invalid duration') unless [7, 30, 90, 180].include?(duration)
      bal = ::DiscourseCoinEngine.coin_user_total(current_user.id)
      return render_json_error('insufficient balance', status: 422) if bal < amount

      multiplier = case duration
                   when 7   then 1.05
                   when 30  then 1.15
                   when 90  then 1.30
                   when 180 then 1.50
                   end

      stake = nil
      ActiveRecord::Base.transaction do
        ::DiscourseCoinEngine.credit_score(current_user.id, Date.today, -amount)
        stake = Stake.create!(
          user_id: current_user.id,
          amount: amount,
          duration_days: duration,
          multiplier: multiplier,
          stakes_at: Time.now,
          unlocks_at: duration.days.from_now,
          status: 'active',
        )
        ::DiscourseCoinEngine.refresh_user_score(current_user.id)
      end
      render json: { id: stake.id, amount: amount, duration_days: duration, multiplier: multiplier, unlocks_at: stake.unlocks_at }
    end

    # POST /coin-engine/economy/stakes/:id/unstake.json
    def unstake
      RateLimiter.new(current_user, 'ce_unstake', 20, 1.day).performed!
      stake = Stake.find_by(id: params[:id], user_id: current_user.id)
      return render_json_error('stake not found', status: 404) unless stake
      return render_json_error('already unstaked') if stake.status != 'active'

      payout = if stake.matured?
                 (stake.amount * stake.multiplier).to_i
               else
                 stake.amount # early unlock = no bonus
               end

      ActiveRecord::Base.transaction do
        ::DiscourseCoinEngine.credit_score(current_user.id, Date.today, payout)
        stake.update!(status: stake.matured? ? 'matured' : 'early_unlocked', rewards_paid: payout - stake.amount)
        ::DiscourseCoinEngine.refresh_user_score(current_user.id)
      end
      render json: { id: stake.id, payout: payout, matured: stake.matured? }
    end

    # GET /coin-engine/economy/stakes.json
    def list_stakes
      stakes = Stake.where(user_id: current_user.id).order(created_at: :desc).limit(50)
      render json: { stakes: stakes.map { |s| serialize_stake(s) } }
    end

    private

    def serialize_tip(t)
      {
        id: t.id, amount: t.amount, note: t.note, post_id: t.post_id, created_at: t.created_at,
        sender: ::User.where(id: t.sender_user_id).pluck(:username).first,
        recipient: ::User.where(id: t.recipient_user_id).pluck(:username).first,
      }
    end

    def serialize_shop_item(i)
      {
        slug: i.slug, name: i.name, description: i.description, icon: i.icon,
        price: i.price, item_type: i.item_type, in_stock: i.in_stock?, stock: i.stock,
      }
    end

    def serialize_bounty(b)
      {
        id: b.id, topic_id: b.topic_id, post_id: b.post_id, amount: b.amount,
        status: b.status, expires_at: b.expires_at, awarded_at: b.awarded_at,
        bounty_type: b.bounty_type, max_winners: b.max_winners,
        invite_count: b.invite_count, window_minutes: b.window_minutes,
        claims_count: b.claims_count, invitation_round: b.invitation_round,
        poster: ::User.where(id: b.poster_user_id).pluck(:username).first,
        winner: b.winner_user_id ? ::User.where(id: b.winner_user_id).pluck(:username).first : nil,
      }
    end

    # ===== On-chain SOL tips (v0.27.0) =====
    # POST /coin-engine/economy/sol_tip/initiate.json { recipient_username, amount_lamports, post_id? }
    # Records a pending P2P SOL tip and returns the recipient wallet + memo for
    # the sender's Phantom to sign a direct transfer.
    def sol_tip_initiate
      RateLimiter.new(current_user, 'coin_engine_sol_tip', 20, 1.hour).performed!
      recipient = ::User.find_by(username_lower: params[:recipient_username].to_s.downcase)
      return render_json_error('recipient not found', status: 404) unless recipient
      return render_json_error('cannot tip yourself', status: 422) if recipient.id == current_user.id
      rwallet, st = ::DiscourseCoinEngine.user_solana_wallet(recipient)
      return render_json_error("@#{recipient.username} hasn't linked a Solana wallet yet.", status: 422) unless st == :ok

      amount = params[:amount_lamports].to_i
      raise ::Discourse::InvalidParameters, 'amount_lamports must be 0.001-100 SOL' if amount < 1_000_000 || amount > 100 * 1_000_000_000

      tip = SolTip.create!(
        sender_user_id: current_user.id, recipient_user_id: recipient.id,
        amount_lamports: amount, recipient_wallet: rwallet, status: 'pending',
        post_id: params[:post_id].presence
      )
      memo = "lf-coin-engine:tip:#{tip.id}:to:#{recipient.id}"
      tip.update_column(:memo, memo)
      render json: { ok: true, tip: tip.serialize_for_user, recipient_username: recipient.username, recipient_wallet: rwallet, amount_lamports: amount, memo: memo }
    rescue RateLimiter::LimitExceeded => e
      render_json_error("Slow down. Try again in #{e.available_in}s.", status: 429)
    rescue ActiveRecord::RecordInvalid => e
      render_json_error(e.record.errors.full_messages.join(', '), status: 422)
    end

    # POST /coin-engine/economy/sol_tip/confirm.json { tip_id, tx_signature }
    def sol_tip_confirm
      tip = SolTip.find_by(id: params[:tip_id].to_i, sender_user_id: current_user.id)
      return render_json_error('tip not found', status: 404) unless tip
      sig = params[:tx_signature].to_s.strip
      raise ::Discourse::InvalidParameters, 'tx_signature' if sig.length < 60 || sig.length > 100
      return render json: { ok: true, tip: tip.serialize_for_user, already: true } unless tip.status == 'pending'
      tip.update!(tx_signature: sig)
      ::Jobs.enqueue_in(2.seconds, :coin_engine_confirm_sol_tip, tip_id: tip.id) if defined?(::Jobs::CoinEngineConfirmSolTip)
      render json: { ok: true, tip: tip.serialize_for_user, queued: true }
    rescue ActiveRecord::RecordNotUnique
      render_json_error('That tx signature is already recorded.', status: 422)
    end

    # GET /coin-engine/economy/sol_tips.json — confirmed SOL tips the user received
    def list_sol_tips
      tips = SolTip.confirmed.for_recipient(current_user.id).recent.limit(50)
      total = SolTip.confirmed.for_recipient(current_user.id).sum(:amount_lamports).to_i
      render json: {
        tips: tips.map { |t| t.serialize_for_user.merge(from: ::User.where(id: t.sender_user_id).pluck(:username).first) },
        total_lamports: total, total_sol: total.to_f / 1_000_000_000
      }
    end

    def serialize_stake(s)
      {
        id: s.id, amount: s.amount, duration_days: s.duration_days,
        multiplier: s.multiplier, stakes_at: s.stakes_at,
        unlocks_at: s.unlocks_at, status: s.status,
        rewards_paid: s.rewards_paid,
      }
    end
  end
end
