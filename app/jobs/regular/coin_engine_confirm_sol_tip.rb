# frozen_string_literal: true

# v0.27.0 — Verifies a Phantom-signed peer-to-peer SOL tip landed on-chain:
# the sender transferred >= amount_lamports to the recipient's wallet, with our
# memo embedded. On success marks confirmed + pushes a MessageBus notice so the
# recipient sees the tip in real time.
module Jobs
  class CoinEngineConfirmSolTip < ::Jobs::Base
    sidekiq_options retry: 6
    RPC_ATTEMPTS = 3

    def execute(args)
      tip = ::DiscourseCoinEngine::SolTip.find_by(id: args[:tip_id].to_i)
      return unless tip
      return unless tip.status == 'pending'
      sig = tip.tx_signature.to_s.strip
      return unless sig.length >= 60

      tx = fetch_tx(sig)
      raise "tx not found yet: #{sig[0,8]}…" unless tx

      if tx.dig('meta', 'err')
        tip.update!(status: 'failed', metadata_json: tip.metadata.merge(rpc_err: tx.dig('meta','err').to_s).to_json)
        return
      end

      unless verify_transfer(tx, tip)
        tip.update!(status: 'failed', metadata_json: tip.metadata.merge(verify_fail: true).to_json)
        return
      end

      tip.update!(status: 'confirmed', confirmed_at: Time.zone.now)
      notify(tip)
      Rails.logger.info("[coin_engine.soltip] tip #{tip.id} confirmed on-chain")
    rescue StandardError => e
      Rails.logger.error("[coin_engine.soltip] confirm tip #{args[:tip_id]} failed: #{e.class}: #{e.message}")
      raise
    end

    private

    def notify(tip)
      sender = ::User.find_by(id: tip.sender_user_id)
      coin_name = (SiteSetting.coin_engine_coin_name rescue '$RENO')
      MessageBus.publish("/coin-engine/credits/#{tip.recipient_user_id}", {
        amount: 0,
        reason: 'sol_tip_received',
        label:  "Received a #{tip.amount_sol.round(4)} SOL tip" + (sender ? " from @#{sender.username}" : ''),
        coin:   coin_name,
        ref:    { kind: 'sol_tip', id: tip.id, tx: tip.tx_signature },
        ts:     Time.now.to_i,
      }, user_ids: [tip.recipient_user_id])
    rescue StandardError => e
      Rails.logger.warn("[coin_engine.soltip] publish failed: #{e.message}")
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

    def verify_transfer(tx, tip)
      memo = "lf-coin-engine:tip:#{tip.id}:to:#{tip.recipient_user_id}"
      return false unless tx.to_json.include?(memo)
      meta = tx['meta'] || {}
      pre  = meta['preBalances']  || []
      post = meta['postBalances'] || []
      keys = (tx.dig('transaction', 'message', 'accountKeys') || []).map { |k| k.is_a?(Hash) ? k['pubkey'] : k }
      idx  = keys.index(tip.recipient_wallet)
      return false unless idx
      (post[idx].to_i - pre[idx].to_i) >= tip.amount_lamports.to_i
    rescue StandardError
      false
    end
  end
end
