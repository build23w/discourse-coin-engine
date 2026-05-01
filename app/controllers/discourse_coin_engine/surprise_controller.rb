# frozen_string_literal: true

# Phase 6 — Surprise & Polish: Daily Chests, Streak Freezes, Auctions, Random Airdrops.
module DiscourseCoinEngine
  class SurpriseController < ::ApplicationController
    requires_login except: [:list_auctions, :show_auction]


    # ===== Daily Chest =====
    # POST /coin-engine/surprise/chest/claim.json
    # Variable-reward draw. 1/day per user.
    def claim_chest
      today = Date.today
      existing = DailyChest.find_by(user_id: current_user.id, claim_date: today)
      return render json: { already_claimed: true, claimed_at: existing.created_at, amount: existing.reward_amount }, status: 200 if existing

      roll = rand
      reward, type =
        if    roll < 0.005 then [1000, 'legendary']
        elsif roll < 0.05  then [200,  'rare']
        elsif roll < 0.20  then [50,   'uncommon']
        else                    [10,   'standard']
        end
      ActiveRecord::Base.transaction do
        ActiveRecord::Base.connection.exec_query(
          "INSERT INTO gamification_scores (user_id, date, score) VALUES ($1, $2, $3)",
          'ce_chest_credit', [current_user.id, today, reward]
        )
        DailyChest.create!(
          user_id: current_user.id,
          claim_date: today,
          reward_amount: reward,
          reward_type: type,
          rarity_roll: roll.round(4).to_s,
        )
        Rails.cache.delete("coin_engine_score_user_#{current_user.id}")
      end
      render json: { claimed: true, amount: reward, rarity: type }
    end

    # ===== Streak Freeze =====
    # POST /coin-engine/surprise/streak_freeze.json { date }
    def use_streak_freeze
      cost = (SiteSetting.coin_engine_streak_freeze_cost rescue 50).to_i
      d = Date.parse(params[:date].to_s) rescue Date.today
      return render_json_error('cannot freeze future dates') if d > Date.today
      return render_json_error('cannot freeze older than 7 days') if d < 7.days.ago.to_date
      bal = ::DiscourseCoinEngine.coin_user_total(current_user.id)
      return render_json_error('insufficient balance', status: 422) if bal < cost
      monthly_cap = (SiteSetting.coin_engine_streak_freeze_monthly_cap rescue 2).to_i
      used_this_month = StreakFreeze.where(user_id: current_user.id).where('freeze_date >= ?', Date.today.beginning_of_month).count
      return render_json_error("monthly cap reached (#{monthly_cap})", status: 422) if used_this_month >= monthly_cap

      f = nil
      ActiveRecord::Base.transaction do
        ActiveRecord::Base.connection.exec_query(
          "INSERT INTO gamification_scores (user_id, date, score) VALUES ($1, $2, $3)",
          'ce_freeze_charge', [current_user.id, Date.today, -cost]
        )
        f = StreakFreeze.create!(user_id: current_user.id, freeze_date: d, cost_paid: cost)
        Rails.cache.delete("coin_engine_score_user_#{current_user.id}")
        Rails.cache.delete("coin_engine_streak_user_#{current_user.id}")
      end
      render json: { id: f.id, freeze_date: f.freeze_date, cost: cost }
    rescue ActiveRecord::RecordNotUnique
      render_json_error('already frozen for that date')
    end

    # ===== Auctions =====
    # GET /coin-engine/surprise/auctions.json (public)
    def list_auctions
      as = Auction.where(status: %w[upcoming live]).order(ends_at: :asc).limit(20)
      render json: { auctions: as.map { |a| serialize_auction(a) } }
    end

    # GET /coin-engine/surprise/auctions/:slug.json
    def show_auction
      a = Auction.find_by(slug: params[:slug])
      return render_json_error('auction not found', status: 404) unless a
      bids = AuctionBid.where(auction_id: a.id).order(amount: :desc).limit(20)
      render json: {
        auction: serialize_auction(a).merge(
          bids: bids.map { |b| { user: ::User.where(id: b.user_id).pluck(:username).first, amount: b.amount, created_at: b.created_at } }
        ),
      }
    end

    # POST /coin-engine/surprise/auctions/:slug/bid.json { amount }
    def bid_auction
      a = Auction.find_by(slug: params[:slug])
      return render_json_error('auction not found', status: 404) unless a
      return render_json_error('auction is not live') unless a.live?
      return render_json_error('auction has ended') if a.ends_at && a.ends_at < Time.now
      amount = params[:amount].to_i
      min_bid = [a.current_bid + 1, a.starting_bid].max
      return render_json_error("minimum bid is #{min_bid}") if amount < min_bid
      bal = ::DiscourseCoinEngine.coin_user_total(current_user.id)
      return render_json_error('insufficient balance', status: 422) if bal < amount

      ActiveRecord::Base.transaction do
        AuctionBid.create!(auction_id: a.id, user_id: current_user.id, amount: amount)
        a.update!(current_bid: amount, leading_user_id: current_user.id)
      end
      render json: { ok: true, current_bid: amount, leader: current_user.username }
    end

    # ===== Random Airdrop history (info only -- creation is via cron job) =====
    # GET /coin-engine/surprise/random_airdrops.json
    def list_random_airdrops
      ras = RandomAirdrop.order(airdrop_date: :desc).limit(20)
      render json: { airdrops: ras.map { |r| { user: ::User.where(id: r.user_id).pluck(:username).first, amount: r.amount, date: r.airdrop_date, reason: r.reason } } }
    end

    private

    def serialize_auction(a)
      { slug: a.slug, item_name: a.item_name, description: a.description, icon: a.icon,
        item_type: a.item_type, starting_bid: a.starting_bid, current_bid: a.current_bid,
        starts_at: a.starts_at, ends_at: a.ends_at, status: a.status,
        leader: a.leading_user_id ? ::User.where(id: a.leading_user_id).pluck(:username).first : nil,
        time_remaining: a.time_remaining }
    end
  end
end
