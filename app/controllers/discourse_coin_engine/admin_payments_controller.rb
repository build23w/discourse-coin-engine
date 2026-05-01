# frozen_string_literal: true

module DiscourseCoinEngine
  class AdminPaymentsController < ::Admin::AdminController
    requires_plugin DiscourseCoinEngine::PLUGIN_NAME

    skip_before_action :preload_json, only: [:index, :embed]
    skip_before_action :check_xhr,     only: [:index, :embed]

    # GET /admin/plugins/coin-engine -- server-rendered HTML admin page.
    # Inline JS hits the JSON endpoints below.
    def index
      respond_to do |format|
        format.html { render layout: 'no_ember', template: 'discourse_coin_engine/admin_payments/index' }
        format.json { list_payments }
      end
    end

    # GET /admin/plugins/coin-engine/embed -- same UI but rendered without the
    # admin chrome so it can be iframed inside the Ember plugin-show page.
    def embed
      response.headers.delete('X-Frame-Options')
      response.headers['Content-Security-Policy'] = "frame-ancestors 'self'"
      render layout: false, template: 'discourse_coin_engine/admin_payments/index'
    end

    # GET /admin/plugins/coin-engine/payments.json
    def list
      list_payments
    end

    # GET /admin/plugins/coin-engine/users/search.json?q=foo
    def search_users
      q = params[:q].to_s.strip.downcase
      return render(json: { users: [] }) if q.length < 2
      users = ::User.where('username_lower LIKE ?', "#{q}%")
                    .where(active: true, suspended_till: nil, silenced_till: nil)
                    .where('id > 0')
                    .order(:username_lower)
                    .limit(10)
      render json: {
        users: users.map { |u|
          {
            id: u.id,
            username: u.username,
            name: u.name,
            avatar_template: u.avatar_template
          }
        }
      }
    end

    # GET /admin/plugins/coin-engine/users/:id/payments.json
    # Recent payments to a specific user (used to surface duplicate risk in the UI)
    def user_payments
      user = ::User.find_by(id: params[:id])
      raise Discourse::NotFound unless user
      payments = ::DiscourseCoinEngine::Payment.for_user(user.id).recent.limit(20)
      render json: { payments: serialize_payments(payments) }
    end

    # POST /admin/plugins/coin-engine/payments.json
    # body: { user_id: N, amount: 250, reason: "Contest winner" }
    def create
      user = ::User.find_by(id: params[:user_id])
      raise Discourse::NotFound unless user
      amount = params[:amount].to_i
      reason = params[:reason].to_s.strip.presence || 'Manual payment'
      raise Discourse::InvalidParameters, 'amount' if amount == 0

      payment = nil
      results = { score_credited: false, ledger_appended: false, email_sent: false, receipt_pm_created: false }

      ActiveRecord::Base.transaction do
        # Credit gamification_scores via raw SQL (bypass model namespace issues)
        begin
          ActiveRecord::Base.connection.exec_insert(
            "INSERT INTO gamification_scores (user_id, date, score) VALUES ($1, $2, $3) ON CONFLICT (user_id, date) DO UPDATE SET score = gamification_scores.score + EXCLUDED.score",
            'coin_engine_credit',
            [user.id, Date.today, amount]
          )
          results[:score_credited] = true
        rescue StandardError => e
          Rails.logger.warn "[coin-engine] manual payment score credit failed: #{e.message}"
        end

        # Cache wallet address at issue time (so the receipt records what wallet
        # was registered when the payment went out, even if user later changes it)
        wallet =
          if SiteSetting.coin_engine_solana_field_id.to_i > 0
            (user.user_fields || {})[SiteSetting.coin_engine_solana_field_id.to_s].to_s
          else
            ''
          end

        payment = ::DiscourseCoinEngine::Payment.create!(
          user_id:           user.id,
          amount:            amount,
          reason:            reason,
          source:            'manual',
          status:            'approved',
          wallet_address:    wallet.presence,
          issued_by_user_id: current_user.id,
          sent_at:           Time.zone.now
        )

        # Append to public ledger
        if SiteSetting.coin_engine_ledger_topic_id.to_i > 0
          begin
            append_to_ledger(user, amount, reason, wallet, payment.id)
            results[:ledger_appended] = true
          rescue StandardError => e
            Rails.logger.warn "[coin-engine] ledger append failed: #{e.message}"
          end
        end

        # Email the recipient
        if SiteSetting.coin_engine_emails_enabled
          begin
            DiscourseCoinEngineMailer.manual_payment_receipt(
              user:         user,
              amount:       amount,
              reason:       reason,
              payment_id:   payment.id,
              issued_by:    current_user.username
            ).deliver_later
            results[:email_sent] = true
          rescue StandardError => e
            Rails.logger.warn "[coin-engine] manual payment email failed: #{e.message}"
          end
        end

        # Create a receipt PM so the user has a permanent record on their inbox
        begin
          create_receipt_pm(user, payment, reason)
          results[:receipt_pm_created] = true
        rescue StandardError => e
          Rails.logger.warn "[coin-engine] receipt PM failed: #{e.message}"
        end
      end

      render json: { ok: true, payment: serialize_payment(payment), results: results }
    end

    # PUT /admin/plugins/coin-engine/payments/:id/tx.json
    # body: { tx_signature: "..." }
    def update_tx_signature
      payment = ::DiscourseCoinEngine::Payment.find_by(id: params[:id])
      raise Discourse::NotFound unless payment
      tx = params[:tx_signature].to_s.strip
      raise Discourse::InvalidParameters, 'tx_signature' if tx.blank?

      payment.update!(tx_signature: tx, tx_added_at: Time.zone.now, status: 'on_chain')

      # Update the public ledger row by editing the receipt PM payment line
      # to include the tx hash. Best-effort.
      begin
        update_ledger_with_tx(payment)
      rescue StandardError => e
        Rails.logger.warn "[coin-engine] ledger tx update failed: #{e.message}"
      end

      render json: { ok: true, payment: serialize_payment(payment) }
    end

    private

    def list_payments
      page  = (params[:page]  || 0).to_i.clamp(0, 1000)
      limit = (params[:limit] || 50).to_i.clamp(1, 200)
      payments = ::DiscourseCoinEngine::Payment.recent.limit(limit).offset(page * limit)
      render json: {
        payments: serialize_payments(payments),
        page:     page,
        limit:    limit
      }
    end

    def serialize_payments(payments)
      payments.includes(:user).map { |p| serialize_payment(p) }
    end

    def serialize_payment(p)
      {
        id:            p.id,
        amount:        p.amount,
        reason:        p.reason,
        source:        p.source,
        status:        p.status,
        tx_signature:  p.tx_signature,
        wallet:        p.wallet_address,
        username:      p.user&.username,
        avatar_template: p.user&.avatar_template,
        issued_by:     ::User.find_by(id: p.issued_by_user_id)&.username,
        created_at:    p.created_at&.iso8601,
        sent_at:       p.sent_at&.iso8601,
        tx_added_at:   p.tx_added_at&.iso8601
      }
    end

    def append_to_ledger(user, amount, reason, wallet, payment_id)
      topic_id = SiteSetting.coin_engine_ledger_topic_id.to_i
      first_post = ::Post.where(topic_id: topic_id).order(:post_number).first
      return unless first_post

      truncated_wallet = wallet.to_s.length > 8 ? "#{wallet[0..3]}...#{wallet[-4..-1]}" : wallet.to_s
      coin = SiteSetting.coin_engine_coin_name
      date = Date.today.strftime('%Y-%m-%d')
      escaped_reason = reason.to_s.gsub('|', '/').gsub("\n", ' ')[0, 200]

      row = "| #{date} | @#{user.username} | #{truncated_wallet} | +#{amount} #{coin} | -- | manual-payment ##{payment_id} | #{escaped_reason} |"
      new_raw = first_post.raw + "\n" + row
      ::PostRevisor.new(first_post).revise!(
        ::Discourse.system_user,
        { raw: new_raw },
        skip_validations: true,
        edit_reason: "coin-engine manual payment #{payment_id}"
      )
    end

    def update_ledger_with_tx(payment)
      topic_id = SiteSetting.coin_engine_ledger_topic_id.to_i
      first_post = ::Post.where(topic_id: topic_id).order(:post_number).first
      return unless first_post
      raw = first_post.raw.to_s
      placeholder = "manual-payment ##{payment.id}"
      return unless raw.include?(placeholder)
      # Find the row and replace the tx column (5th column, currently '--')
      lines = raw.split("\n")
      lines.each_with_index do |line, i|
        next unless line.include?(placeholder)
        cells = line.split('|')
        # Cells: ['', date, user, wallet, amount, tx_column, type, notes, '']
        if cells.length >= 6
          cells[5] = " #{payment.tx_signature[0..15]}... "
          lines[i] = cells.join('|')
        end
      end
      new_raw = lines.join("\n")
      return if new_raw == raw
      ::PostRevisor.new(first_post).revise!(
        ::Discourse.system_user,
        { raw: new_raw },
        skip_validations: true,
        edit_reason: "coin-engine: tx signature for payment #{payment.id}"
      )
    end

    def create_receipt_pm(user, payment, reason)
      coin    = SiteSetting.coin_engine_coin_name
      ledger  = "/t/#{SiteSetting.coin_engine_ledger_topic_id}"
      title   = "Receipt: #{payment.amount} #{coin} credited to your account"
      issuer  = ::User.find_by(id: payment.issued_by_user_id)&.username || 'system'
      tx_line = payment.tx_signature.presence || '_pending mint -- transaction signature will be added once on-chain._'
      raw = <<~MD
        Hi @#{user.username},

        Your account has been credited with **#{payment.amount} #{coin}**.

        | Field | Value |
        |---|---|
        | Receipt # | ##{payment.id} |
        | Amount | +#{payment.amount} #{coin} |
        | Reason | #{reason} |
        | Issued by | @#{issuer} |
        | Date | #{payment.created_at.strftime('%Y-%m-%d %H:%M UTC')} |
        | On-chain tx | #{tx_line} |

        Your full balance and rank are visible on the [leaderboard](/leaderboard/1). The full audit trail is on the [public payment ledger](#{ledger}).

        This is a system receipt -- replying here is fine, but the credit is already final.
      MD

      ::PostCreator.create!(
        ::Discourse.system_user,
        target_usernames: user.username,
        archetype:        ::Archetype.private_message,
        title:            title,
        raw:              raw,
        skip_validations: true
      )
    end
  end
end
