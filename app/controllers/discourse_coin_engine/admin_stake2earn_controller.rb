# frozen_string_literal: true

# v0.36.0 - GET /admin/coin-engine/stake2earn.json
# The staker audit, automated: every on-chain top-list staker with its
# matched forum identity (linked wallet / custodial / treasury / unknown)
# and first-seen date. This replaces manual wallet forensics.
module DiscourseCoinEngine
  class AdminStake2earnController < ::Admin::AdminController
    requires_plugin DiscourseCoinEngine::PLUGIN_NAME

    def index
      set = ::DiscourseCoinEngine::Stake2Earn.stakers
      first_seen = ::DiscourseCoinEngine::Stake2Earn.first_seen_map
      treasury = (SiteSetting.coin_engine_treasury_wallet rescue '').to_s.strip
      field_key = "user_field_#{(SiteSetting.coin_engine_solana_field_id rescue 1).to_i}"

      linked = ::UserCustomField.where(name: field_key, value: set.keys).pluck(:value, :user_id).to_h
      custodial = begin
        ::DiscourseCoinEngine::CustodialWallet.active.where(public_key: set.keys).pluck(:public_key, :user_id).to_h
      rescue StandardError
        {}
      end
      usernames = ::User.where(id: (linked.values + custodial.values).uniq).pluck(:id, :username).to_h

      rows = set.sort_by { |_o, s| -s }.map do |owner, stake|
        source, user_id =
          if owner == treasury then ['treasury', nil]
          elsif linked[owner] then ['linked', linked[owner]]
          elsif custodial[owner] then ['custodial', custodial[owner]]
          else ['unknown', nil]
          end
        {
          owner: owner,
          stake: ::DiscourseCoinEngine::Stake2Earn.ui(stake),
          source: source,
          username: user_id ? usernames[user_id] : nil,
          first_seen: first_seen[owner],
        }
      end

      render json: {
        vault: ::DiscourseCoinEngine::Stake2Earn.vault_address,
        staker_count: rows.size,
        total_staked: ::DiscourseCoinEngine::Stake2Earn.ui(set.values.sum),
        unknown_share: (rows.select { |r| r[:source] == 'unknown' }.sum { |r| r[:stake] }),
        stakers: rows,
      }
    end
  end
end
