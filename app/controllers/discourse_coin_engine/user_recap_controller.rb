# frozen_string_literal: true

module DiscourseCoinEngine
  class UserRecapController < ::ApplicationController
    requires_plugin DiscourseCoinEngine::PLUGIN_NAME
    skip_before_action :preload_json
    skip_before_action :check_xhr

    def show
      raise Discourse::NotFound unless SiteSetting.coin_engine_enabled

      user = User.find_by(username_lower: params[:username].to_s.downcase)
      raise Discourse::NotFound unless user

      one_week_ago = 7.days.ago

      week_score = ::GamificationScore.where(user_id: user.id, date: one_week_ago.to_date..Date.today).sum(:score) rescue 0
      total_score = ::GamificationScore.where(user_id: user.id).sum(:score) rescue 0

      # Rank delta vs. last week
      this_week_top = LeaderboardQuery.new(period: 'all', limit: 5000).call
      this_rank = this_week_top.find { |r| r[:user_id] == user.id }&.dig(:rank)
      last_week_top = LeaderboardQuery.new(period: 'all_excluding_last_week', limit: 5000).call
      last_rank = last_week_top.find { |r| r[:user_id] == user.id }&.dig(:rank)
      rank_delta = (this_rank && last_rank) ? (last_rank - this_rank) : nil

      # Tier
      tier = TierResolver.new(total_score).call

      # Recent badges (last 7 days)
      recent_badges = UserBadge.where(user_id: user.id)
                               .where('granted_at >= ?', one_week_ago)
                               .includes(:badge)
                               .order(granted_at: :desc)
                               .limit(20)
                               .map { |ub| { id: ub.badge_id, name: ub.badge.display_name, granted_at: ub.granted_at.iso8601 } }

      # Streak
      streak = StreakCalculator.new(user_id: user.id).current

      render json: {
        username: user.username,
        coin_name: SiteSetting.coin_engine_coin_name,
        total: total_score.to_i,
        week_earned: week_score.to_i,
        rank: this_rank,
        rank_delta: rank_delta,
        tier: tier,
        streak_days: streak,
        recent_badges: recent_badges,
        generated_at: Time.zone.now.iso8601
      }
    end

    # GET /coin-engine/user/:username/payments.json
    # Returns the user's recent payments (receipts). Public endpoint -- the same
    # data is on the public ledger topic, just structured. Used by the component
    # to render a "Recent receipts" card on profile pages.
    def payments
      raise Discourse::NotFound unless SiteSetting.coin_engine_enabled
      user = User.find_by(username_lower: params[:username].to_s.downcase)
      raise Discourse::NotFound unless user

      # v0.8.3: hard cap at 30 max, default 3 per page. User-facing endpoint is
      # rate-limited by this cap to prevent ?limit=99999 enumeration. Pagination
      # is page+per_page based.
      per_page = (params[:limit] || params[:per_page] || 3).to_i.clamp(1, 30)
      page     = (params[:page] || 1).to_i.clamp(1, 1000)
      scope    = ::DiscourseCoinEngine::Payment.where(user_id: user.id).order(created_at: :desc)
      total    = scope.count
      payments = scope.limit(per_page).offset((page - 1) * per_page)

      render json: {
        username:  user.username,
        coin_name: SiteSetting.coin_engine_coin_name,
        ledger_topic_url: "/t/#{SiteSetting.coin_engine_ledger_topic_id}",
        page:      page,
        per_page:  per_page,
        total:     total,
        has_more:  total > page * per_page,
        payments: payments.map { |p|
          {
            id:           p.id,
            amount:       p.amount,
            reason:       p.reason,
            source:       p.source,
            status:       p.status,
            tx_signature: p.tx_signature,
            tx_explorer:  p.tx_signature.present? ? "https://solscan.io/tx/#{p.tx_signature}" : nil,
            created_at:   p.created_at&.iso8601,
            sent_at:      p.sent_at&.iso8601
          }
        }
      }
    end
  end
end
