# frozen_string_literal: true

module DiscourseCoinEngine
  class AdminAirdropController < ::ApplicationController
    requires_plugin DiscourseCoinEngine::PLUGIN_NAME
    before_action :ensure_logged_in
    # v0.10.2 — was ensure_staff (allows mods); promoted to admin-only since
    # this endpoint mints $RENO. Mods retain read access via the public ledger.
    before_action :ensure_admin
    skip_before_action :preload_json
    skip_before_action :check_xhr

    # POST /coin-engine/admin/airdrop.json
    # body: { username: "x", amount: 250, reason: "Contest winner", source: "manual" }
    #
    # Effects:
    # 1. Inserts a row into gamification_scores (date today, score amount).
    # 2. Appends a row to the public payment ledger topic (if configured).
    # 3. Optionally sends the recipient an airdrop notification email.
    # 4. Optionally posts to the configured outbound webhook.
    #
    # All four steps are best-effort -- if any one fails, the others still run, and the response
    # tells the admin which steps succeeded.
    def create
      raise Discourse::NotFound unless SiteSetting.coin_engine_enabled

      username = params[:username].to_s
      amount   = params[:amount].to_i
      reason   = params[:reason].to_s.presence || 'manual airdrop'
      source   = params[:source].to_s.presence || 'admin-airdrop'

      raise Discourse::InvalidParameters, 'amount' if amount == 0
      # v0.10.2 — defense-in-depth: cap a single airdrop. Compromised admin
      # account or fat-finger typo could otherwise nuke the economy.
      max_single = (SiteSetting.coin_engine_max_airdrop_amount rescue 1_000_000).to_i
      if amount.abs > max_single
        raise Discourse::InvalidParameters, "amount exceeds max single airdrop (#{max_single})"
      end
      user = User.find_by(username_lower: username.downcase)
      raise Discourse::NotFound unless user

      results = { score_credited: false, ledger_appended: false, email_sent: false, webhook_posted: false }

      # 1. Credit gamification score (v0.12.1 - via credit_score helper so the
      # leaderboard ledger gets the mirrored write; otherwise /leaderboard/N
      # would never show airdropped amounts)
      begin
        ::DiscourseCoinEngine.credit_score(user.id, Date.today, amount)
        ::DiscourseCoinEngine.refresh_user_score(user.id) if ::DiscourseCoinEngine.respond_to?(:refresh_user_score)
        results[:score_credited] = true
      rescue StandardError => e
        Rails.logger.warn "[coin-engine] airdrop score credit failed: #{e.message}"
      end

      # 2. Append to public ledger topic
      if SiteSetting.coin_engine_ledger_topic_id.to_i > 0
        begin
          append_to_ledger(user: user, amount: amount, reason: reason, source: source)
          results[:ledger_appended] = true
        rescue StandardError => e
          Rails.logger.warn "[coin-engine] airdrop ledger append failed: #{e.message}"
        end
      end

      # 3. Email recipient
      if SiteSetting.coin_engine_emails_enabled && user.email_digests
        begin
          DiscourseCoinEngineMailer.airdrop_notification(user: user, amount: amount, reason: reason).deliver_later
          results[:email_sent] = true
        rescue StandardError => e
          Rails.logger.warn "[coin-engine] airdrop email failed: #{e.message}"
        end
      end

      # 4. Webhook
      webhook_url = SiteSetting.coin_engine_webhook_url.to_s
      if webhook_url.present? && SiteSetting.coin_engine_webhook_events.to_s.include?('airdrop')
        begin
          require 'net/http'
          require 'resolv'
          uri = URI.parse(webhook_url)
          # v0.10.2 — SSRF defense: only http/https, only public IPs.
          unless %w[http https].include?(uri.scheme)
            raise "webhook scheme must be http(s)"
          end
          # Resolve hostname → IP, refuse private/link-local/loopback ranges.
          # An admin can still set a public webhook (the intended use), but a
          # compromised SiteSetting can't probe internal services.
          resolved = (Resolv.getaddresses(uri.host) || []).first
          if resolved && private_ip?(resolved)
            raise "webhook host resolves to private IP: #{resolved}"
          end
          payload = { event: 'airdrop', username: user.username, amount: amount, reason: reason, source: source, at: Time.zone.now.iso8601 }.to_json
          Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', open_timeout: 5, read_timeout: 5) do |http|
            req = Net::HTTP::Post.new(uri.path.presence || '/', { 'Content-Type' => 'application/json' })
            req.body = payload
            http.request(req)
          end
          results[:webhook_posted] = true
        rescue StandardError => e
          Rails.logger.warn "[coin-engine] airdrop webhook failed: #{e.message}"
        end
      end

      render json: { ok: true, username: user.username, amount: amount, reason: reason, results: results }
    end

    private

    # v0.10.2 - block private IP ranges + loopback + link-local + metadata IP
    # to prevent SSRF via the webhook setting.
    def private_ip?(addr)
      return false unless addr
      ip = IPAddr.new(addr) rescue nil
      return true unless ip
      [
        '10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16',
        '127.0.0.0/8',
        '169.254.0.0/16',
        '::1/128', 'fc00::/7', 'fe80::/10',
        '0.0.0.0/8',
      ].any? { |range| IPAddr.new(range).include?(ip) rescue false }
    end

    def append_to_ledger(user:, amount:, reason:, source:)
      topic_id = SiteSetting.coin_engine_ledger_topic_id.to_i
      first_post = Post.where(topic_id: topic_id).order(:post_number).first
      return unless first_post

      wallet = ''
      if SiteSetting.coin_engine_solana_field_id.to_i > 0
        wallet_full = (user.user_fields || {})[SiteSetting.coin_engine_solana_field_id.to_s].to_s
        wallet = wallet_full.length > 8 ? "#{wallet_full[0..3]}...#{wallet_full[-4..-1]}" : wallet_full
      end

      date = Date.today.strftime('%Y-%m-%d')
      coin = SiteSetting.coin_engine_coin_name
      row = "| #{date} | @#{user.username} | #{wallet} | +#{amount} #{coin} | -- | airdrop | #{reason.gsub('|','/')} |"

      new_raw = first_post.raw + "\n" + row
      revisor = ::PostRevisor.new(first_post)
      revisor.revise!(Discourse.system_user, { raw: new_raw }, skip_validations: true, edit_reason: "coin-engine airdrop append")
    end
  end
end
