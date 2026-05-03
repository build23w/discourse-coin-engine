# frozen_string_literal: true

# v0.12.2 - Verifies a Phantom-signed stake transfer landed on-chain.
# Mirrors CoinEngineConfirmPhantomPurchase logic against staking treasury.

module Jobs
  class CoinEngineConfirmStake < ::Jobs::Base
    sidekiq_options retry: 6
    RPC_ATTEMPTS = 3

    def execute(args)
      sid = args[:stake_id].to_i
      return if sid <= 0
      stake = ::DiscourseCoinEngine::SolStake.find_by(id: sid)
      return unless stake
      return unless stake.status == 'pending'
      sig = stake.stake_tx.to_s.strip
      return unless sig.length >= 60

      treasury = staking_treasury
      if treasury.empty?
        Rails.logger.warn("[coin_engine.staking] treasury unset; cannot confirm stake #{sid}")
        return
      end

      tx = fetch_tx(sig)
      raise "tx not found yet: #{sig[0,8]}…" unless tx

      err = tx.dig('meta', 'err')
      if err
        stake.update!(status: 'failed', metadata_json: stake.metadata.merge(rpc_err: err.to_s).to_json)
        Rails.logger.warn("[coin_engine.staking] stake #{sid} tx failed: #{err}")
        return
      end

      ok = verify_transfer(tx, stake, treasury)
      unless ok
        stake.update!(status: 'failed', metadata_json: stake.metadata.merge(verify_fail: true).to_json)
        Rails.logger.warn("[coin_engine.staking] stake #{sid} tx didn't match expected transfer")
        return
      end

      stake.update!(status: 'active', confirmed_at: Time.zone.now)
      begin
        coin_name = (SiteSetting.coin_engine_coin_name rescue '$RENO')
        MessageBus.publish("/coin-engine/credits/#{stake.user_id}", {
          amount: 0,
          reason: 'stake_confirmed',
          label:  "Stake confirmed (#{stake.amount_sol.round(4)} SOL)",
          coin:   coin_name,
          ref:    { kind: 'stake', id: stake.id, tx: stake.stake_tx },
          ts:     Time.now.to_i,
        }, user_ids: [stake.user_id])
      rescue StandardError => e
        Rails.logger.warn("[coin_engine.staking] publish failed: #{e.message}")
      end
      Rails.logger.info("[coin_engine.staking] stake #{sid} confirmed on-chain")
    rescue StandardError => e
      Rails.logger.error("[coin_engine.staking] confirm stake #{args[:stake_id]} failed: #{e.class}: #{e.message}")
      raise
    end

    private

    def staking_treasury
      st = (SiteSetting.coin_engine_staking_treasury rescue '').to_s.strip
      return st unless st.empty?
      (SiteSetting.coin_engine_treasury_wallet rescue '').to_s.strip
    end

    def fetch_tx(sig)
      rpc = (SiteSetting.coin_engine_solana_rpc_url rescue '').to_s.strip
      rpc = 'https://api.mainnet-beta.solana.com' if rpc.empty?
      body = { jsonrpc: '2.0', id: 1, method: 'getTransaction',
               params: [sig, { encoding: 'jsonParsed', commitment: 'confirmed', maxSupportedTransactionVersion: 0 }] }.to_json
      RPC_ATTEMPTS.times do |i|
        begin
          uri = URI(rpc)
          req = Net::HTTP::Post.new(uri.request_uri, 'Content-Type' => 'application/json')
          req.body = body
          res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', read_timeout: 10) { |h| h.request(req) }
          parsed = JSON.parse(res.body) rescue nil
          return parsed['result'] if parsed && parsed['result']
        rescue StandardError
          nil
        end
        sleep 2 if i < RPC_ATTEMPTS - 1
      end
      nil
    end

    def verify_transfer(tx, stake, treasury)
      memo = "lf-coin-engine:stake:#{stake.id}:user:#{stake.user_id}"
      return false unless tx.to_json.include?(memo)
      meta = tx['meta'] || {}
      pre  = meta['preBalances']  || []
      post = meta['postBalances'] || []
      keys = (tx.dig('transaction', 'message', 'accountKeys') || []).map { |k| k.is_a?(Hash) ? k['pubkey'] : k }
      idx  = keys.index(treasury)
      return false unless idx
      delta = (post[idx].to_i - pre[idx].to_i)
      delta >= stake.amount_lamports.to_i
    rescue StandardError
      false
    end
  end
end
