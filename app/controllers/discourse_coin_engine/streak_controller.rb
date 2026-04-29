# frozen_string_literal: true

module DiscourseCoinEngine
  class StreakController < ::ApplicationController
    requires_plugin DiscourseCoinEngine::PLUGIN_NAME
    skip_before_action :preload_json
    skip_before_action :check_xhr

    def show
      raise Discourse::NotFound unless SiteSetting.coin_engine_enabled

      user = User.find_by(username_lower: params[:username].to_s.downcase)
      raise Discourse::NotFound unless user

      calc = StreakCalculator.new(user_id: user.id)
      render json: {
        username: user.username,
        current_days: calc.current,
        longest_days: calc.longest,
        last_visit_at: calc.last_visit_at&.iso8601,
        at_risk: calc.at_risk?
      }
    end
  end
end
