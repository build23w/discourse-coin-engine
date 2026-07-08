# frozen_string_literal: true

require 'net/http'
require 'base64'

# v0.36.0 - Stake2Earn bridge. Reads Meteora M3M3 (stake-for-fee) program
# state for the community token vault straight from the chain, matches escrow
# owners to forum accounts (linked Phantom wallets via the solana user_field
# + plugin custodial wallets), and feeds the staker set to the boost engine,
# diamond-hands quests, public endpoints and the admin audit.
#
# On-chain layout (verified against MeteoraAg/stake-for-fee-sdk IDL 2026-07-08):
#   FeeVault:        disc(8) + lockEscrow(32) stakeMint(32) quoteMint(32)
#                    pool(32) stakeTokenVault(32) quoteTokenVault(32)
#                    topStakerList(32) fullBalanceList(32) ...
#   TopStakerList:   disc(8) + vault(32) + N x StakerMetadata
#   StakerMetadata:  stakeAmount(u64 LE) fullBalanceIndex(i64) owner(32)
module ::DiscourseCoinEngine
  class Stake2Earn
    STORE = 'discourse-coin-engine'
    FIRST_SEEN_KEY = 's2e_first_seen'
    STAKE_FIELD  = 'coin_engine_staker_stake'
    WALLET_FIELD = 'coin_engine_staker_wallet'
    B58 = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz'

    class << self
      def enabled?
        !!(SiteSetting.coin_engine_enabled && SiteSetting.coin_engine_stake2earn_enabled)
      rescue StandardError
        false
      end

      def vault_address
        (SiteSetting.coin_engine_m3m3_vault rescue '').to_s.strip
      end

      def decimals
        (SiteSetting.coin_engine_solana_decimals rescue 9).to_i
      end

      def ui(raw)
        raw.to_f / (10**decimals)
      end

      # { owner_pubkey => raw_stake }, cached. Empty hash on any failure.
      def stakers(force: false)
        return {} unless enabled? && vault_address.present?
        Rails.cache.delete('ce_s2e_stakers_v1') if force
        Rails.cache.fetch('ce_s2e_stakers_v1', expires_in: 10.minutes) { fetch_stakers } || {}
      rescue StandardError => e
        Rails.logger.warn("[coin-engine] s2e stakers failed: #{e.message}")
        {}
      end

      # Meteora API display stats (TVL/daily rewards), cached 10 min. nil-safe.
      def pool_stats
        return nil unless enabled? && vault_address.present?
        Rails.cache.fetch('ce_s2e_pool_stats_v1', expires_in: 10.minutes) do
          base = (SiteSetting.coin_engine_m3m3_api_base rescue 'https://stake-for-fee-api.meteora.ag').to_s
          body = http_get("#{base}/vault/#{vault_address}")
          json = JSON.parse(body) rescue nil
          next nil unless json.is_a?(Hash) && json['vault_address']
          {
            'total_staked' => json['total_staked_amount'],
            'daily_reward_usd' => json['daily_reward_usd'],
            'current_reward_usd' => json['current_reward_usd'],
            'seconds_to_full_unlock' => json['seconds_to_full_unlock'],
            'tvl_threshold_reached' => json.dig('flags', 'tvl_usd_threshold_reached'),
          }
        end
      rescue StandardError
        nil
      end

      # { user_id => { wallet:, stake_raw: } } - forum accounts currently in
      # the on-chain top-staker list, matched via linked wallet field OR
      # plugin custodial wallet.
      def forum_stakers(staker_set = nil)
        set = staker_set || stakers
        return {} if set.empty?
        out = {}
        wallets = set.keys
        field_key = "user_field_#{(SiteSetting.coin_engine_solana_field_id rescue 1).to_i}"
        ::UserCustomField.where(name: field_key, value: wallets).pluck(:user_id, :value).each do |uid, w|
          out[uid] ||= { wallet: w, stake_raw: set[w].to_i, source: 'linked' }
        end
        begin
          ::DiscourseCoinEngine::CustodialWallet.active.where(public_key: wallets).pluck(:user_id, :public_key).each do |uid, w|
            out[uid] ||= { wallet: w, stake_raw: set[w].to_i, source: 'custodial' }
          end
        rescue StandardError
          # custodial table may not exist on older installs
        end
        out
      end

      # PluginStore-backed continuity ledger: { owner => iso8601 first seen }.
      # Owners that drop out of the staker set are removed (streak broken).
      def first_seen_map
        ::PluginStore.get(STORE, FIRST_SEEN_KEY) || {}
      end

      def update_first_seen!(staker_set)
        map = first_seen_map
        now = Time.now.iso8601
        staker_set.each_key { |o| map[o] ||= now }
        map.select! { |o, _| staker_set.key?(o) }
        ::PluginStore.set(STORE, FIRST_SEEN_KEY, map)
        map
      end

      # Boost/quest view of a user's staking state (from sync-job fields; no
      # RPC on the request path). nil when not currently a verified staker.
      def staker_info_for_user(user)
        return nil unless user
        cf = ::UserCustomField.where(user_id: user.id, name: [STAKE_FIELD, WALLET_FIELD]).pluck(:name, :value).to_h
        stake = cf[STAKE_FIELD].to_i
        return nil if stake <= 0
        wallet = cf[WALLET_FIELD].to_s
        since = first_seen_map[wallet]
        { wallet: wallet, stake_raw: stake, stake_ui: ui(stake),
          first_seen: (Time.parse(since) rescue nil) }
      end

      # Recent treasury signatures for the transparency page (archive RPC),
      # cached 15 min. [] on failure.
      def treasury_activity(limit: 20)
        treasury = (SiteSetting.coin_engine_treasury_wallet rescue '').to_s.strip
        return [] if treasury.blank?
        Rails.cache.fetch('ce_s2e_treasury_v1', expires_in: 15.minutes) do
          url = (SiteSetting.coin_engine_solana_archive_rpc_url rescue '').to_s.presence || 'https://api.mainnet-beta.solana.com'
          res = rpc_call(url, 'getSignaturesForAddress', [treasury, { limit: limit.to_i.clamp(1, 50) }])
          (res || []).map do |s|
            { 'signature' => s['signature'], 'block_time' => s['blockTime'], 'err' => !!s['err'] }
          end
        end || []
      rescue StandardError
        []
      end

      # ---- low level ------------------------------------------------------

      def fetch_stakers
        vault_data = account_data(vault_address)
        return nil unless vault_data && vault_data.length >= 264
        top_list_addr = b58encode(vault_data[200, 32])
        list = account_data(top_list_addr)
        return nil unless list && list.length > 40
        out = {}
        off = 40
        while off + 48 <= list.length
          stake = list[off, 8].unpack1('Q<')
          owner = b58encode(list[off + 16, 32])
          out[owner] = stake if stake > 0 && owner != '11111111111111111111111111111111'
          off += 48
        end
        out
      end

      def account_data(pubkey)
        res = nil
        rpc_candidates.each do |url|
          res = rpc_call(url, 'getAccountInfo', [pubkey, { encoding: 'base64' }])
          break if res && res['value']
        end
        return nil unless res && res['value'] && res['value']['data']
        Base64.decode64(res['value']['data'][0].to_s)
      end

      def rpc_candidates
        primary = (SiteSetting.coin_engine_solana_rpc_url rescue '').to_s.strip
        list = []
        list << primary if primary.present?
        list + %w[https://solana-rpc.publicnode.com https://api.mainnet-beta.solana.com]
      end

      def rpc_call(url, method, params)
        uri = URI(url)
        req = Net::HTTP::Post.new(uri.request_uri, 'Content-Type' => 'application/json',
                                                   'User-Agent' => 'Mozilla/5.0 (coin-engine)')
        req.body = { jsonrpc: '2.0', id: 1, method: method, params: params }.to_json
        res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https',
                              read_timeout: 8, open_timeout: 4) { |h| h.request(req) }
        parsed = JSON.parse(res.body) rescue nil
        parsed && parsed['result']
      rescue StandardError => e
        Rails.logger.debug("[coin-engine] s2e rpc #{method} via #{url}: #{e.class}")
        nil
      end

      def http_get(url)
        uri = URI(url)
        req = Net::HTTP::Get.new(uri.request_uri, 'User-Agent' => 'Mozilla/5.0 (coin-engine)')
        res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https',
                              read_timeout: 8, open_timeout: 4) { |h| h.request(req) }
        res.body
      end

      def b58encode(bytes)
        n = bytes.unpack1('H*').to_i(16)
        out = +''
        while n > 0
          n, r = n.divmod(58)
          out.prepend(B58[r])
        end
        bytes.each_byte { |b| b.zero? ? out.prepend('1') : break }
        out
      end
    end
  end
end
