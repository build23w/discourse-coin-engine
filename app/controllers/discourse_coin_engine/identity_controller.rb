# frozen_string_literal: true

# Phase 4 — Identity & Insights: Achievements, Tournaments, AMA, Quest Suggestions, Photo Bounties, $RENO Wrapped.
module DiscourseCoinEngine
  class IdentityController < ::ApplicationController
    requires_login except: [:list_tournaments, :show_tournament, :show_wrapped, :list_user_achievements]


    # ===== Achievements =====
    # GET /coin-engine/identity/u/:username/achievements.json
    def list_user_achievements
      user = ::User.find_by(username_lower: params[:username].to_s.downcase)
      return render_json_error('user not found', status: 404) unless user
      achs = Achievement.where(user_id: user.id).visible.order(unlocked_at: :desc).limit(100)
      render json: { achievements: achs.map { |a| { slug: a.slug, name: a.name, description: a.description, icon: a.icon, reward: a.reward, unlocked_at: a.unlocked_at } } }
    end

    # ===== Tournaments =====
    # GET /coin-engine/identity/tournaments.json
    def list_tournaments
      tns = Tournament.where(status: %w[upcoming active voting]).order(starts_at: :desc).limit(20)
      render json: { tournaments: tns.map { |t| serialize_tournament(t) } }
    end

    # GET /coin-engine/identity/tournaments/:slug.json
    def show_tournament
      t = Tournament.find_by(slug: params[:slug])
      return render_json_error('tournament not found', status: 404) unless t
      entries = TournamentEntry.where(tournament_id: t.id).order(vote_count: :desc).limit(100)
      entry_data = entries.map do |e|
        { user: ::User.where(id: e.user_id).pluck(:username).first, topic_id: e.topic_id,
          post_id: e.post_id, votes: e.vote_count }
      end
      render json: { tournament: serialize_tournament(t).merge(entries: entry_data) }
    end

    # POST /coin-engine/identity/tournaments/:slug/enter.json { topic_id?, post_id? }
    def enter_tournament
      t = Tournament.find_by(slug: params[:slug])
      return render_json_error('tournament not found', status: 404) unless t
      return render_json_error('tournament not open for entries') unless %w[upcoming active].include?(t.status)
      e = TournamentEntry.create!(
        tournament_id: t.id,
        user_id: current_user.id,
        topic_id: params[:topic_id].presence,
        post_id: params[:post_id].presence,
      )
      render json: { entry_id: e.id }
    end

    # POST /coin-engine/identity/tournaments/:slug/vote.json { entry_id }
    def vote_tournament
      t = Tournament.find_by(slug: params[:slug])
      return render_json_error('tournament not found', status: 404) unless t
      return render_json_error('tournament not in voting phase') unless t.status == 'voting'
      e = TournamentEntry.find_by(id: params[:entry_id], tournament_id: t.id)
      return render_json_error('entry not found', status: 404) unless e
      e.increment!(:vote_count)
      render json: { entry_id: e.id, votes: e.vote_count }
    end

    # ===== AMA Bookings =====
    # POST /coin-engine/identity/ama.json { title, description, scheduled_at }
    def create_ama_booking
      cost = (SiteSetting.coin_engine_ama_booking_cost rescue 100).to_i
      bal = ::DiscourseCoinEngine.coin_user_total(current_user.id)
      return render_json_error('insufficient balance', status: 422) if bal < cost
      scheduled = Time.parse(params[:scheduled_at].to_s) rescue nil
      return render_json_error('invalid scheduled_at') unless scheduled

      booking = nil
      ActiveRecord::Base.transaction do
        # v0.12.1 - credit_score helper so leaderboard ledger gets the debit too
        ::DiscourseCoinEngine.credit_score(current_user.id, Date.today, -cost)
        booking = AmaBooking.create!(
          user_id: current_user.id,
          title: params[:title].to_s[0, 200],
          description: params[:description].to_s[0, 5000],
          scheduled_at: scheduled,
          paid_amount: cost,
          status: 'scheduled',
        )
        ::DiscourseCoinEngine.refresh_user_score(current_user.id)
      end
      render json: { id: booking.id, scheduled_at: booking.scheduled_at, cost: cost }
    end

    # GET /coin-engine/identity/ama.json
    def list_ama_bookings
      ams = AmaBooking.upcoming.order(scheduled_at: :asc).limit(20)
      render json: { bookings: ams.map { |a| { id: a.id, user: ::User.where(id: a.user_id).pluck(:username).first, title: a.title, scheduled_at: a.scheduled_at, status: a.status } } }
    end

    # ===== Quest Suggestions =====
    # POST /coin-engine/identity/quest_suggestions.json { title, description }
    def create_quest_suggestion
      qs = QuestSuggestion.create!(
        suggester_user_id: current_user.id,
        title: params[:title].to_s[0, 200],
        description: params[:description].to_s[0, 5000],
        status: 'pending',
      )
      render json: { id: qs.id, status: 'pending' }
    end

    # GET /coin-engine/identity/quest_suggestions.json (admins see pending; users see their own)
    def list_quest_suggestions
      list = current_user.admin? ? QuestSuggestion.where(status: 'pending') : QuestSuggestion.where(suggester_user_id: current_user.id)
      render json: { suggestions: list.order(created_at: :desc).limit(50).map { |q| { id: q.id, title: q.title, description: q.description, status: q.status, created_at: q.created_at } } }
    end

    # ===== Photo Bounties =====
    # POST /coin-engine/identity/photo_bounties.json { name, requirements, reward, expires_in_days?, max_winners? }
    def create_photo_bounty
      reward = params[:reward].to_i
      return render_json_error('reward must be positive') if reward <= 0
      bal = ::DiscourseCoinEngine.coin_user_total(current_user.id)
      return render_json_error('insufficient balance', status: 422) if bal < reward
      expires_in = (params[:expires_in_days].presence || 14).to_i.clamp(1, 60)

      pb = nil
      ActiveRecord::Base.transaction do
        # v0.12.1 - credit_score helper so leaderboard ledger gets the debit too
        ::DiscourseCoinEngine.credit_score(current_user.id, Date.today, -reward)
        pb = PhotoBounty.create!(
          poster_user_id: current_user.id,
          name: params[:name].to_s[0, 200],
          requirements: params[:requirements].to_s[0, 5000],
          reward: reward,
          max_winners: params[:max_winners].to_i.clamp(1, 10),
          status: 'active',
          expires_at: expires_in.days.from_now,
        )
        ::DiscourseCoinEngine.refresh_user_score(current_user.id)
      end
      render json: { id: pb.id, expires_at: pb.expires_at }
    end

    # GET /coin-engine/identity/photo_bounties.json
    def list_photo_bounties
      pbs = PhotoBounty.active.order(created_at: :desc).limit(20)
      render json: { photo_bounties: pbs.map { |p| { id: p.id, poster: ::User.where(id: p.poster_user_id).pluck(:username).first, name: p.name, requirements: p.requirements, reward: p.reward, max_winners: p.max_winners, awarded_count: p.awarded_count, expires_at: p.expires_at } } }
    end

    # ===== $RENO Wrapped =====
    # GET /coin-engine/identity/wrapped/:username.json (public)
    # Returns annual recap data: total earned, top categories, top topics, badges, streaks, rank journey.
    def show_wrapped
      user = ::User.find_by(username_lower: params[:username].to_s.downcase)
      return render_json_error('user not found', status: 404) unless user
      data = Rails.cache.fetch("coin_engine_wrapped_#{user.id}_#{Date.today.year}", expires_in: 6.hours) do
        year_start = Date.new(Date.today.year, 1, 1)
        score_year = ActiveRecord::Base.connection.exec_query(
          "SELECT COALESCE(SUM(score),0)::int AS s FROM gamification_scores WHERE user_id = $1 AND date >= $2",
          'ce_wrap_score', [user.id, year_start]
        ).rows.first&.first || 0
        posts_year = ::Post.where(user_id: user.id).where('created_at >= ?', year_start).count
        topics_year = ::Topic.where(user_id: user.id).where('created_at >= ?', year_start).count
        likes_received = ::Post.where(user_id: user.id).where('created_at >= ?', year_start).sum(:like_count)
        badges_year = ::UserBadge.where(user_id: user.id).where('granted_at >= ?', year_start).count
        top_topic = ::Topic.where(user_id: user.id).where('created_at >= ?', year_start)
          .order(like_count: :desc).limit(1).pluck(:id, :title, :slug, :like_count).first
        {
          username: user.username,
          year: Date.today.year,
          score_year: score_year,
          posts_year: posts_year,
          topics_year: topics_year,
          likes_received: likes_received,
          badges_year: badges_year,
          top_topic: top_topic && { id: top_topic[0], title: top_topic[1], slug: top_topic[2], likes: top_topic[3] },
        }
      end
      render json: data
    end

    private

    def serialize_tournament(t)
      { slug: t.slug, name: t.name, description: t.description, type: t.tournament_type,
        starts_at: t.starts_at, ends_at: t.ends_at, status: t.status, prize_pool: t.prize_pool,
        winner: t.winner_user_id ? ::User.where(id: t.winner_user_id).pluck(:username).first : nil }
    end
  end
end
