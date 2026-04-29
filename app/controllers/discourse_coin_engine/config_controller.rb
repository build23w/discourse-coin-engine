# frozen_string_literal: true

module DiscourseCoinEngine
  class ConfigController < ::ApplicationController
    requires_plugin DiscourseCoinEngine::PLUGIN_NAME
    skip_before_action :preload_json
    skip_before_action :check_xhr

    def show
      raise Discourse::NotFound unless SiteSetting.coin_engine_enabled

      thresholds = SiteSetting.coin_engine_tier_thresholds.to_s.split('|').map { |v| v.strip.to_i }
      names      = SiteSetting.coin_engine_tier_names.to_s.split('|').map(&:strip)

      tiers =
        if thresholds.length == names.length && thresholds.length > 0
          thresholds.zip(names).map { |t, n| { 'min' => t, 'name' => n } }
        else
          [
            { 'min' => 0,     'name' => 'Beginner' },
            { 'min' => 100,   'name' => 'Bronze'   },
            { 'min' => 1000,  'name' => 'Silver'   },
            { 'min' => 5000,  'name' => 'Gold'     },
            { 'min' => 25000, 'name' => 'Platinum' },
            { 'min' => 50000, 'name' => 'Diamond'  }
          ]
        end

      render json: {
        enabled:           true,
        coin_name:         SiteSetting.coin_engine_coin_name,
        coin_symbol:       SiteSetting.coin_engine_coin_symbol,
        brand_color:       SiteSetting.coin_engine_brand_color,
        welcome_topic_id:  SiteSetting.coin_engine_welcome_topic_id,
        ledger_topic_id:   SiteSetting.coin_engine_ledger_topic_id,
        solana_field_id:   SiteSetting.coin_engine_solana_field_id,
        tiers:             tiers,
        features: {
          weekly_digest:        SiteSetting.coin_engine_weekly_digest_enabled,
          personal_recap:       SiteSetting.coin_engine_personal_recap_enabled,
          streak_warning:       SiteSetting.coin_engine_streak_warning_enabled,
          dormant_reengage:     SiteSetting.coin_engine_dormant_reengage_enabled,
          tier_up_email:        SiteSetting.coin_engine_tier_up_email_enabled,
          webhook_outbound:     SiteSetting.coin_engine_webhook_url.present?
        }
      }
    end
  end
end
