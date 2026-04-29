# frozen_string_literal: true

module DiscourseCoinEngine
  class LeaderboardController < ::ApplicationController
    requires_plugin DiscourseCoinEngine::PLUGIN_NAME
    skip_before_action :preload_json
    skip_before_action :check_xhr

    PERIODS = %w[week month all].freeze

    def index
      raise Discourse::NotFound unless SiteSetting.coin_engine_enabled

      period = params[:period].to_s
      period = 'all' unless PERIODS.include?(period)
      limit = (params[:limit] || 25).to_i.clamp(1, 100)

      rows = LeaderboardQuery.new(period: period, limit: limit).call

      personal = nil
      if current_user
        my_row = rows.find { |r| r[:user_id] == current_user.id }
        personal = {
          rank:        my_row && my_row[:rank],
          total:       my_row && my_row[:total],
          username:    current_user.username,
          name:        current_user.name
        }
      end

      render json: {
        period: period,
        users:  rows,
        personal: personal,
        coin_name: SiteSetting.coin_engine_coin_name,
        generated_at: Time.zone.now.iso8601
      }
    end
  end
end
