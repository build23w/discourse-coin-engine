# frozen_string_literal: true

# v0.36.0 - Public Stake2Earn surface.
#   GET /coin-engine/stake2earn/status.json   - pool stats + (if logged in) my stake/boost
#   GET /coin-engine/stake2earn/treasury.json - recent on-chain treasury activity (transparency)
module DiscourseCoinEngine
  class Stake2earnController < ::ApplicationController
    requires_plugin DiscourseCoinEngine::PLUGIN_NAME
    skip_before_action :check_xhr, raise: false

    def status
      raise Discourse::NotFound unless ::DiscourseCoinEngine::Stake2Earn.enabled?

      set   = ::DiscourseCoinEngine::Stake2Earn.stakers
      stats = ::DiscourseCoinEngine::Stake2Earn.pool_stats
      total_raw = set.values.sum

      payload = {
        ok: true,
        vault: ::DiscourseCoinEngine::Stake2Earn.vault_address,
        staker_count: set.size,
        total_staked: ::DiscourseCoinEngine::Stake2Earn.ui(total_raw),
        pool: stats,
        boost: {
          enabled: !!SiteSetting.coin_engine_staker_boost_enabled,
          multiplier: SiteSetting.coin_engine_staker_boost_multiplier.to_f,
          daily_cap: SiteSetting.coin_engine_staker_boost_daily_cap.to_i,
        },
        meteora_url: (SiteSetting.coin_engine_meteora_stake_url rescue '').to_s.presence,
        coin: SiteSetting.coin_engine_coin_name,
      }

      if current_user
        info = ::DiscourseCoinEngine::Stake2Earn.staker_info_for_user(current_user)
        payload[:me] =
          if info
            {
              staking: true,
              stake: info[:stake_ui],
              wallet: info[:wallet],
              staker_since: info[:first_seen]&.iso8601,
              days_staked: info[:first_seen] ? ((Time.now - info[:first_seen]) / 86_400).floor : nil,
            }
          else
            { staking: false }
          end
      end

      render json: payload
    end

    def treasury
      raise Discourse::NotFound unless ::DiscourseCoinEngine::Stake2Earn.enabled?
      treasury = (SiteSetting.coin_engine_treasury_wallet rescue '').to_s.strip
      rows = ::DiscourseCoinEngine::Stake2Earn.treasury_activity
      render json: {
        ok: true,
        treasury: treasury,
        recent: rows.map { |r|
          r.merge('solscan' => "https://solscan.io/tx/#{r['signature']}")
        },
      }
    end
  end
end
