# frozen_string_literal: true

# v0.35.0 - GET /admin/coin-engine/email_stats.json?days=14
# Per-day / per-campaign / per-city email funnel (sent -> clicked -> rewarded).
module DiscourseCoinEngine
  class AdminEmailStatsController < ::Admin::AdminController
    requires_plugin DiscourseCoinEngine::PLUGIN_NAME

    def index
      days = (params[:days].presence || 14).to_i.clamp(1, 60)
      render json: { days: days, stats: ::DiscourseCoinEngine::EmailStats.summary(days: days) }
    end
  end
end
