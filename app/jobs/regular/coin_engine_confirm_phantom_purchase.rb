# frozen_string_literal: true

# v0.12.0 - Verifies a Phantom-signed SOL transfer landed on-chain.
#
# Strategy:
#   1. Fetch the tx via Solana RPC getTransaction(sig, json)
#   2. Confirm it transfers >= expected lamports from purchase.wallet_used
#      to SiteSetting.coin_engine_treasury_wallet
#   3. Confirm the memo contains "lf-coin-engine:purchase:#{purchase.id}"
#   4. On success: status='paid', paid_at=now, then enqueue fulfillment

module Jobs
  class CoinEngineConfirmPhantomPurchase < ::Jobs::Base
    sidekiq_options retry: 6  # exponential backoff covers up to ~10min

    RPC_ATTEMPTS = 3
    REQUIRED_CONFIRMATIONS = 1  # 'confirmed' commitment is enough for memo verification

    def execute(args)
      purchase_id = args[:purchase_id].to_i
      return if purchase_id <= 0

      purchase = ::DiscourseCoinEngine::StorePurchase.find_by(id: purchase_id)
      return unless purchase
      return unless purchase.pending?
      sig = purchase.tx_signature.to_s.strip
      return unless sig.length >= 60

      treasury = SiteSetting.coin_engine_treasury_wallet.to_s.strip rescue ''
      if treasury.empty?
        Rails.logger.warn("[coin_engine] treasury wallet unset, cannot confirm purchase #{purchase_id}")
        return
      end

      tx = fetch_tx(sig)
      unless tx
        # Tx not yet on-chain (or RPC blip) — let Sidekiq retry
        raise "tx not found yet: #{sig[0,8]}…"
      end

      err = tx.dig('meta', 'err')
      if err
        purchase.update!(status: 'failed', metadata_json: purchase.metadata.merge(rpc_err: err.to_s).to_json)
        Rails.logger.warn("[coin_engine] purchase #{purchase_id} tx failed on-chain: #{err}")
        return
      end

      ok = verify_transfer(tx, purchase, treasury)
      unless ok
        purchase.update!(status: 'failed', metadata_json: purchase.metadata.merge(verify_fail: true).to_json)
        Rails.logger.warn("[coin_engine] purchase #{purchase_id} tx didn't match expected transfer")
        return
      end

      purchase.update!(status: 'paid', paid_at: Time.zone.now)

      ::Jobs.enqueue(:coin_engine_fulfill_store_purchase, purchase_id: purchase.id) if defined?(::Jobs::CoinEngineFulfillStorePurchase)

      Rails.logger.info("[coin_engine] purchase #{purchase_id} confirmed on-chain")
    rescue StandardError => e
      Rails.logger.error("[coin_engine] confirm_phantom_purchase failed for #{args[:purchase_id]}: #{e.class}: #{e.message}")
      raise
    end

    private

    def fetch_tx(sig)
      rpc = SiteSetting.coin_engine_solana_rpc_url.to_s.strip rescue ''
      rpc = 'https://api.mainnet-beta.solana.com' if rpc.empty?
      body = {
        jsonrpc: '2.0', id: 1, method: 'getTransaction',
        params: [sig, { encoding: 'jsonParsed', commitment: 'confirmed', maxSupportedTransactionVersion: 0 }],
      }.to_json

      RPC_ATTEMPTS.times do |i|
        begin
          uri = URI(rpc)
          req = Net::HTTP::Post.new(uri.request_uri, 'Content-Type' => 'application/json')
          req.body = body
          res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', read_timeout: 10) { |h| h.request(req) }
          parsed = JSON.parse(res.body) rescue nil
          return parsed['result'] if parsed && parsed['result']
        rescue StandardError => e
          Rails.logger.debug("[coin_engine] RPC fetch attempt #{i+1} failed: #{e.class}: #{e.message}")
        end
        sleep 2 if i < RPC_ATTEMPTS - 1
      end
      nil
    end

    def verify_transfer(tx, purchase, treasury)
      memo = "lf-coin-engine:purchase:#{purchase.id}:user:#{purchase.user_id}"
      tx_str = tx.to_json

      # Memo present?
      return false unless tx_str.include?(memo)

      # Treasury balance went up by at least amount_paid lamports?
      meta = tx['meta'] || {}
      pre  = meta['preBalances']  || []
      post = meta['postBalances'] || []
      keys = (tx.dig('transaction', 'message', 'accountKeys') || []).map { |k| k.is_a?(Hash) ? k['pubkey'] : k }
      idx  = keys.index(treasury)
      return false unless idx
      delta = (post[idx].to_i - pre[idx].to_i)
      delta >= purchase.amount_paid.to_i
    rescue StandardError => e
      Rails.logger.error("[coin_engine] verify_transfer threw: #{e.class}: #{e.message}")
      false
    end
  end
end
