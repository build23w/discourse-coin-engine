# frozen_string_literal: true

module DiscourseCoinEngine
  class PaymentsController < ::ApplicationController
    requires_plugin DiscourseCoinEngine::PLUGIN_NAME
    skip_before_action :preload_json
    skip_before_action :check_xhr

    def index
      raise Discourse::NotFound unless SiteSetting.coin_engine_enabled

      topic_id = SiteSetting.coin_engine_ledger_topic_id.to_i
      raise Discourse::NotFound if topic_id <= 0

      limit = (params[:limit] || 50).to_i.clamp(1, 500)

      entries = LedgerParser.new(topic_id: topic_id, limit: limit).call

      render json: {
        topic_id: topic_id,
        topic_url: "/t/#{topic_id}",
        entries: entries,
        coin_name: SiteSetting.coin_engine_coin_name,
        generated_at: Time.zone.now.iso8601
      }
    end
  end
end
