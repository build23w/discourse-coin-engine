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
      raise Discourse::InvalidAccess unless current_user
      recipient = ::User.find_by(username_lower: params[:recipient_username].to_s.downcase)
      return render_json_error('recipient not found', status: 404) unless recipient
      amount = params[:amount].to_i
      return render_json_error('amount must be positive') if amount <= 0
      return render_json_error('cannot tip yourself') if recipient.id == current_user.id
      sender_balance = ::DiscourseCoinEngine.coin_user_total(current_user.id)
      return render_json_error('insufficient balance', status: 422) if sender_balance < amount

      tip = nil
      ActiveRecord::Base.transaction do
        # Debit sender, credit recipient via gamification_scores rows.
        ts = Date.today
        ActiveRecord::Base.connection.exec_query(
          "INSERT INTO gamification_scores (user_id, date, score) VALUES ($1, $2, $3) ON CONFLICT (user_id, date) DO UPDATE SET score = gamification_scores.score + EXCLUDED.score",
          'ce_tip_debit', [current_user.id, ts, -amount]
        )
        ActiveRecord::Base.connection.exec_query(
          "INSERT INTO gamification_scores (user_id, date, score) VALUES ($1, $2, $3) ON CONFLICT (user_id, date) DO UPDATE SET score = gamification_scores.score + EXCLUDED.score",
          'ce_tip_credit', [recipient.id, ts, amount]
        )
        tip = Tip.create!(
          sender_user_id: current_user.id,
          recipient_user_id: recipient.id,
          post_id: params[:post_id].presence,
          amount: amount,
          note: params[:note].to_s[0, 280],
          status: 'sent',
        )
        Rails.cache.delete("coin_engine_score_user_#{current_user.id}")
        Rails.cache.delete("coin_engine_score_user_#{recipient.id}")
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
      item = ShopItem.enabled.find_by(slug: params[:slug])
      return render_json_error('item not found', status: 404) unless item
      return render_json_error('out of stock', status: 422) unless item.in_stock?
      bal = ::DiscourseCoinEngine.coin_user_total(current_user.id)
      return render_json_error('insufficient balance', status: 422) if bal < item.price

      red = nil
      ActiveRecord::Base.transaction do
        ActiveRecord::Base.connection.exec_query(
          "INSERT INTO gamification_scores (user_id, date, score) VALUES ($1, $2, $3) ON CONFLICT (user_id, date) DO UPDATE SET score = gamification_scores.score + EXCLUDED.score",
          'ce_redeem_debit', [current_user.id, Date.today, -item.price]
        )
        red = Redemption.create!(
          user_id: current_user.id,
          shop_item_id: item.id,
          price_paid: item.price,
          payload: item.payload,
          status: 'active',
        )
        item.decrement!(:stock) if item.stock > 0
        Rails.cache.delete("coin_engine_score_user_#{current_user.id}")
      end
      render json: { redemption_id: red.id, item: item.slug, expires_at: red.expires_at }
    end

    # GET /coin-engine/economy/redemptions.json
    def list_redemptions
      reds = Redemption.where(user_id: current_user.id).order(created_at: :desc).limit(50)
      render json: { redemptions: reds.map { |r| { id: r.id, item_slug: r.shop_item&.slug, status: r.status, expires_at: r.expires_at, price_paid: r.price_paid } } }
    end

    # ===== Bounties =====
    # POST /coin-engine/economy/bounties.json { topic_id, post_id?, amount, note?, expires_in_days? }
    def create_bounty
      amount = params[:amount].to_i
      return render_json_error('amount must be positive') if amount <= 0
      bal = ::DiscourseCoinEngine.coin_user_total(current_user.id)
      return render_json_error('insufficient balance', status: 422) if bal < amount

      topic = ::Topic.find_by(id: params[:topic_id])
      return render_json_error('topic not found', status: 404) unless topic
      expires_in = (params[:expires_in_days].presence || 7).to_i.clamp(1, 30)

      bounty = nil
      ActiveRecord::Base.transaction do
        ActiveRecord::Base.connection.exec_query(
          "INSERT INTO gamification_scores (user_id, date, score) VALUES ($1, $2, $3) ON CONFLICT (user_id, date) DO UPDATE SET score = gamification_scores.score + EXCLUDED.score",
          'ce_bounty_lock', [current_user.id, Date.today, -amount]
        )
        bounty = Bounty.create!(
          poster_user_id: current_user.id,
          topic_id: topic.id,
          post_id: params[:post_id].presence,
          amount: amount,
          status: 'open',
          expires_at: expires_in.days.from_now,
          note: params[:note].to_s[0, 1000],
        )
        Rails.cache.delete("coin_engine_score_user_#{current_user.id}")
      end
      render json: { id: bounty.id, amount: amount, expires_at: bounty.expires_at }
    end

    # POST /coin-engine/economy/bounties/:id/award.json { winning_post_id }
    def award_bounty
      bounty = Bounty.find_by(id: params[:id])
      return render_json_error('bounty not found', status: 404) unless bounty
      return render_json_error('only the poster can award', status: 403) unless bounty.poster_user_id == current_user.id
      return render_json_error('bounty is not open', status: 422) unless bounty.open?
      post = ::Post.find_by(id: params[:winning_post_id])
      return render_json_error('post not found', status: 404) unless post
      winner = ::User.find_by(id: post.user_id)
      return render_json_error('winner not found', status: 404) unless winner

      ActiveRecord::Base.transaction do
        ActiveRecord::Base.connection.exec_query(
          "INSERT INTO gamification_scores (user_id, date, score) VALUES ($1, $2, $3) ON CONFLICT (user_id, date) DO UPDATE SET score = gamification_scores.score + EXCLUDED.score",
          'ce_bounty_award', [winner.id, Date.today, bounty.amount]
        )
        bounty.update!(status: 'awarded', winner_user_id: winner.id, winning_post_id: post.id, awarded_at: Time.now)
        Rails.cache.delete("coin_engine_score_user_#{winner.id}")
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
        ActiveRecord::Base.connection.exec_query(
          "INSERT INTO gamification_scores (user_id, date, score) VALUES ($1, $2, $3) ON CONFLICT (user_id, date) DO UPDATE SET score = gamification_scores.score + EXCLUDED.score",
          'ce_stake_lock', [current_user.id, Date.today, -amount]
        )
        stake = Stake.create!(
          user_id: current_user.id,
          amount: amount,
          duration_days: duration,
          multiplier: multiplier,
          stakes_at: Time.now,
          unlocks_at: duration.days.from_now,
          status: 'active',
        )
        Rails.cache.delete("coin_engine_score_user_#{current_user.id}")
      end
      render json: { id: stake.id, amount: amount, duration_days: duration, multiplier: multiplier, unlocks_at: stake.unlocks_at }
    end

    # POST /coin-engine/economy/stakes/:id/unstake.json
    def unstake
      stake = Stake.find_by(id: params[:id], user_id: current_user.id)
      return render_json_error('stake not found', status: 404) unless stake
      return render_json_error('already unstaked') if stake.status != 'active'

      payout = if stake.matured?
                 (stake.amount * stake.multiplier).to_i
               else
                 stake.amount # early unlock = no bonus
               end
      ActiveRecord::Base.transaction do
        ActiveRecord::Base.connection.exec_query(
          "INSERT INTO gamification_scores (user_id, date, score) VALUES ($1, $2, $3) ON CONFLICT (user_id, date) DO UPDATE SET score = gamification_scores.score + EXCLUDED.score",
          'ce_stake_payout', [current_user.id, Date.today, payout]
        )
        stake.update!(status: stake.matured? ? 'matured' : 'early_unlocked', rewards_paid: payout - stake.amount)
        Rails.cache.delete("coin_engine_score_user_#{current_user.id}")
      end
      render json: { id: stake.id, payout: payout, matured: stake.matured? }
    end

    # GET /coin-engine/economy/stakes.json
    def list_stakes
      stakes = Stake.where(user_id: current_user.id).order(created_at: :desc).limit(50)
      render json: { stakes: stakes.map { |s| { id: s.id, amount: s.amount, duration_days: s.duration_days, multiplier: s.multiplier, status: s.status, unlocks_at: s.unlocks_at } } }
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
        poster: ::User.where(id: b.poster_user_id).pluck(:username).first,
        winner: b.winner_user_id ? ::User.where(id: b.winner_user_id).pluck(:username).first : nil,
      }
    end
  end
end
