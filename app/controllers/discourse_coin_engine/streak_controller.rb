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
      payload = {
        username: user.username,
        current_days: calc.current,
        longest_days: calc.longest,
      }
      if current_user && (current_user.id == user.id || current_user.staff?)
        payload[:last_visit_at] = calc.last_visit_at&.iso8601
        payload[:at_risk] = calc.at_risk?
      end
      render json: payload
    end
  end
end
