# frozen_string_literal: true

# v0.8.4 — Public transparency ledger.
#
# Tips, bounties, DAO ballots, redemptions are recorded in their own tables
# but were not exposed in a single public view. This controller aggregates
# the most recent activity across all economy/governance events so the FAB
# Ledger tab can show "what happened across the community in the last X
# events" without anyone needing to be staff.
#
# Privacy: usernames + amounts + timestamps + free-form notes ARE shown.
# The same data is already on the public ledger topic for payments.
#
# All endpoints are anonymous (no requires_login) so they can be embedded in
# the public profile pages and be crawled.

module DiscourseCoinEngine
  class PublicLedgerController < ::ApplicationController
    skip_before_action :check_xhr, only: [:recent, :tips, :bounties, :votes, :redemptions]

    # GET /coin-engine/ledger/recent.json?limit=50
    # Combined feed across all event tables, newest first.
    def recent
      limit = (params[:limit] || 50).to_i.clamp(1, 200)
      events = []

      # Tips (sender → recipient, amount)
      Tip.order(created_at: :desc).limit(limit).each do |t|
        sender = ::User.find_by(id: t.sender_user_id)
        recip  = ::User.find_by(id: t.recipient_user_id)
        events << {
          type: 'tip',
          ts: t.created_at.to_i,
          amount: t.amount.to_i,
          sender:    sender ? { username: sender.username, name: sender.name } : nil,
          recipient: recip  ? { username: recip.username,  name: recip.name  } : nil,
          note: t.note.to_s.presence,
          post_id: t.post_id,
        }
      end

      # Awarded bounties
      Bounty.where(status: 'awarded').order(awarded_at: :desc).limit(limit).each do |b|
        poster = ::User.find_by(id: b.poster_user_id)
        winner = ::User.find_by(id: b.winner_user_id)
        events << {
          type: 'bounty',
          ts: (b.awarded_at || b.created_at).to_i,
          amount: b.amount.to_i,
          sender:    poster ? { username: poster.username, name: poster.name } : nil,
          recipient: winner ? { username: winner.username, name: winner.name } : nil,
          note: b.topic&.title.to_s.presence, # CE-015: Bounty has no title column
          post_id: b.winning_post_id,
        }
      end

      # DAO ballots — anonymous-tally style (no individual ballot reveal of who voted what)
      VoteBallot.order(created_at: :desc).limit(limit).each do |vb|
        v = Vote.find_by(id: vb.vote_id)
        u = ::User.find_by(id: vb.user_id)
        next unless v
        events << {
          type: 'dao_vote',
          ts: vb.created_at.to_i,
          amount: vb.weight.to_i,        # weight, NOT $RENO movement
          sender:    u ? { username: u.username, name: u.name } : nil,
          recipient: nil,
          note: "Voted on \"#{v.title}\"",
          ref_slug: v.slug,
        }
      end

      # Redemptions
      if defined?(Redemption)
        Redemption.order(created_at: :desc).limit(limit).each do |r|
          u = ::User.find_by(id: r.user_id)
          item = ShopItem.find_by(id: r.shop_item_id)
          events << {
            type: 'redemption',
            ts: r.created_at.to_i,
            amount: r.price_paid.to_i,
            sender:    u ? { username: u.username, name: u.name } : nil,
            recipient: nil,
            note: item ? "Redeemed \"#{item.title}\"" : 'Shop redemption',
          }
        end
      end

      # Manual + on-chain payments (Payment model — these are the staff-issued
      # awards and Solana mints. Probably the most-watched ledger entry type
      # since they include real on-chain tx signatures users can verify.)
      ::DiscourseCoinEngine::Payment
        .where.not(status: %w[cancelled refunded failed])
        .order(Arel.sql('COALESCE(sent_at, created_at) DESC'))
        .limit(limit)
        .each do |p|
          recip = ::User.find_by(id: p.user_id)
          issuer = p.issued_by_user_id ? ::User.find_by(id: p.issued_by_user_id) : nil
          events << {
            type: 'payment',
            ts: (p.sent_at || p.created_at).to_i,
            amount: p.amount.to_i,
            sender:    issuer ? { username: issuer.username, name: issuer.name } : nil,
            recipient: recip  ? { username: recip.username,  name: recip.name  } : nil,
            note: p.reason.to_s.presence,
            tx_signature: p.tx_signature,
            tx_explorer:  p.tx_signature ? "https://solscan.io/tx/#{p.tx_signature}" : nil,
            payment_id: p.id,
            status: p.status,
          }
        end

      events.sort_by! { |e| -e[:ts] }
      events = events.first(limit)

      render json: {
        coin: SiteSetting.coin_engine_coin_name,
        count: events.length,
        events: events,
      }
    rescue StandardError => e
      Rails.logger.error("[coin_engine] PublicLedger#recent: #{e.class}: #{e.message}")
      render json: { events: [], error: e.message }, status: 200
    end

    # GET /coin-engine/ledger/tips.json?page=1&limit=20
    def tips
      page  = (params[:page]  || 1).to_i.clamp(1, 1000)
      limit = (params[:limit] || 20).to_i.clamp(1, 100)
      scope = Tip.order(created_at: :desc)
      total = scope.count
      tips  = scope.limit(limit).offset((page - 1) * limit)
      render json: render_paginated(tips, page, limit, total) { |t| serialize_tip(t) }
    end

    # GET /coin-engine/ledger/bounties.json?page=1&limit=20
    def bounties
      page  = (params[:page]  || 1).to_i.clamp(1, 1000)
      limit = (params[:limit] || 20).to_i.clamp(1, 100)
      scope = Bounty.where(status: 'awarded').order(awarded_at: :desc)
      total = scope.count
      bs    = scope.limit(limit).offset((page - 1) * limit)
      render json: render_paginated(bs, page, limit, total) { |b| serialize_bounty(b) }
    end

    # GET /coin-engine/ledger/votes.json?page=1&limit=20
    def votes
      page  = (params[:page]  || 1).to_i.clamp(1, 1000)
      limit = (params[:limit] || 20).to_i.clamp(1, 100)
      scope = VoteBallot.order(created_at: :desc)
      total = scope.count
      bs    = scope.limit(limit).offset((page - 1) * limit)
      render json: render_paginated(bs, page, limit, total) { |b| serialize_ballot(b) }
    end

    # GET /coin-engine/ledger/payments.json?page=1&limit=20
    # Manual staff-issued payments + on-chain Solana mints. Filtered to exclude
    # cancelled/refunded/failed so only the "real" community-visible audit lives here.
    def payments
      page  = (params[:page]  || 1).to_i.clamp(1, 1000)
      limit = (params[:limit] || 20).to_i.clamp(1, 100)
      scope = ::DiscourseCoinEngine::Payment
                .where.not(status: %w[cancelled refunded failed])
                .order(Arel.sql('COALESCE(sent_at, created_at) DESC'))
      total = scope.count
      ps    = scope.limit(limit).offset((page - 1) * limit)
      render json: render_paginated(ps, page, limit, total) { |p| serialize_payment(p) }
    end

    # GET /coin-engine/ledger/redemptions.json?page=1&limit=20
    def redemptions
      return render(json: { items: [], total: 0, page: 1, per_page: 20 }) unless defined?(Redemption)
      page  = (params[:page]  || 1).to_i.clamp(1, 1000)
      limit = (params[:limit] || 20).to_i.clamp(1, 100)
      scope = Redemption.order(created_at: :desc)
      total = scope.count
      rs    = scope.limit(limit).offset((page - 1) * limit)
      render json: render_paginated(rs, page, limit, total) { |r| serialize_redemption(r) }
    end

    private

    def render_paginated(records, page, limit, total)
      items = records.map { |r| yield(r) }
      {
        coin: SiteSetting.coin_engine_coin_name,
        page: page,
        per_page: limit,
        total: total,
        has_more: total > page * limit,
        items: items,
      }
    end

    def serialize_tip(t)
      sender = ::User.find_by(id: t.sender_user_id)
      recip  = ::User.find_by(id: t.recipient_user_id)
      {
        id: t.id, ts: t.created_at.to_i, amount: t.amount.to_i,
        sender:    sender ? { username: sender.username, name: sender.name } : nil,
        recipient: recip  ? { username: recip.username,  name: recip.name  } : nil,
        note: t.note.to_s.presence, post_id: t.post_id,
      }
    end

    def serialize_bounty(b)
      poster = ::User.find_by(id: b.poster_user_id)
      winner = b.winner_user_id ? ::User.find_by(id: b.winner_user_id) : nil
      {
        id: b.id,
        ts: (b.awarded_at || b.created_at).to_i,
        amount: b.amount.to_i,
        title: b.topic&.title.to_s, # CE-015: Bounty has no title column
        poster: poster ? { username: poster.username, name: poster.name } : nil,
        winner: winner ? { username: winner.username, name: winner.name } : nil,
        winning_post_id: b.winning_post_id,
        status: b.status,
      }
    end

    def serialize_ballot(b)
      v = Vote.find_by(id: b.vote_id)
      u = ::User.find_by(id: b.user_id)
      {
        id: b.id, ts: b.created_at.to_i, weight: b.weight.to_i,
        voter: u ? { username: u.username, name: u.name } : nil,
        vote_slug: v&.slug, vote_title: v&.title,
        option_key: b.option_key,
      }
    end

    def serialize_payment(p)
      recip  = ::User.find_by(id: p.user_id)
      issuer = p.issued_by_user_id ? ::User.find_by(id: p.issued_by_user_id) : nil
      {
        id: p.id,
        ts: (p.sent_at || p.created_at).to_i,
        amount: p.amount.to_i,
        recipient: recip  ? { username: recip.username,  name: recip.name  } : nil,
        sender:    issuer ? { username: issuer.username, name: issuer.name } : nil,
        reason: p.reason.to_s,
        status: p.status,
        wallet: p.wallet_address.to_s.presence,
        tx_signature: p.tx_signature,
        tx_explorer: p.tx_signature ? "https://solscan.io/tx/#{p.tx_signature}" : nil,
      }
    end

    def serialize_redemption(r)
      u = ::User.find_by(id: r.user_id)
      item = ShopItem.find_by(id: r.shop_item_id)
      {
        id: r.id, ts: r.created_at.to_i, price_paid: r.price_paid.to_i,
        user: u ? { username: u.username, name: u.name } : nil,
        item: item ? { slug: item.slug, title: item.title } : nil,
        status: r.status,
      }
    end
  end
end
