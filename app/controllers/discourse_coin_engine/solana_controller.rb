# frozen_string_literal: true

# v0.12.7 - Server-side Solana RPC proxy.
#
# Why this exists:
#   - The browser-side "Buy $RENO" flow used to call new web3.Connection(...)
#     and conn.getLatestBlockhash() against api.mainnet-beta.solana.com.
#   - That endpoint blocks browser CORS calls with 403, so every Buy $RENO
#     attempt died before Phantom even saw the transaction.
#   - We already have a server-side RPC fallback chain for confirm jobs;
#     re-use it here so the browser only ever talks to our origin.
#
# Endpoints:
#   GET /coin-engine/solana/recent_blockhash.json
#     -> { blockhash: "...", last_valid_block_height: 12345, rpc_used: "..." }
#
# The shapes match what window.solanaWeb3 expects to feed into a
# Transaction.recentBlockhash field, so the browser can build + sign a tx
# without ever hitting a 3rd-party RPC.

require 'net/http'
require 'json'

module DiscourseCoinEngine
  class SolanaController < ::ApplicationController
    requires_login
    before_action :ensure_logged_in
    skip_before_action :check_xhr, raise: false

    # CORS-friendly public RPCs we'll try in order. Mirrors the list in the
    # admin payments view (PUBLIC_RPC_FALLBACKS) so the server and admin UI
    # behave consistently. Admin can paste a private RPC into the
    # coin_engine_solana_rpc_url SiteSetting; that takes precedence.
    PUBLIC_FALLBACKS = [
      'https://solana-rpc.publicnode.com',
      'https://rpc.ankr.com/solana',
      'https://api.mainnet-beta.solana.com',
    ].freeze

    def recent_blockhash
      Rails.logger.info("[coin_engine.solana] recent_blockhash user=#{current_user&.id}")
      RateLimiter.new(current_user, 'coin_engine_solana_blockhash', 60, 1.hour).performed!

      result = call_rpc(
        method:  'getLatestBlockhash',
        params:  [{ commitment: 'finalized' }],
      )

      unless result && result['value']
        return render json: { errors: ['Could not fetch a recent blockhash from any RPC. Try again in a minute.'] }, status: 503
      end

      val = result['value']
      render json: {
        ok: true,
        blockhash:               val['blockhash'],
        last_valid_block_height: val['lastValidBlockHeight'],
        rpc_used:                @rpc_used,
        commitment:              'finalized',
      }
    rescue RateLimiter::LimitExceeded => e
      render json: { errors: ["Slow down. Try again in #{e.available_in}s."] }, status: 429
    end

    private

    def rpc_candidates
      override = (SiteSetting.coin_engine_solana_rpc_url rescue '').to_s.strip
      list = []
      list << override if override.present?
      PUBLIC_FALLBACKS.each { |u| list << u unless list.include?(u) }
      list
    end

    def call_rpc(method:, params:)
      body = { jsonrpc: '2.0', id: 1, method: method, params: params }.to_json
      rpc_candidates.each do |url|
        begin
          uri = URI(url)
          req = Net::HTTP::Post.new(uri.request_uri, 'Content-Type' => 'application/json', 'Accept' => 'application/json')
          req.body = body
          res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', read_timeout: 8, open_timeout: 5) { |h| h.request(req) }
          parsed = JSON.parse(res.body) rescue nil
          if parsed && parsed['result']
            @rpc_used = url
            return parsed['result']
          else
            Rails.logger.debug("[coin_engine.solana] #{method} via #{url} returned no result: code=#{res.code} body=#{res.body.to_s[0,200]}")
          end
        rescue StandardError => e
          Rails.logger.debug("[coin_engine.solana] #{method} via #{url} failed: #{e.class}: #{e.message[0,160]}")
        end
      end
      nil
    end
  end
end
