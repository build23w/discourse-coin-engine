# frozen_string_literal: true

# v0.11.0 — Admin endpoints for the Withdraw Requests tab.

module DiscourseCoinEngine
  class AdminWithdrawRequestsController < ::Admin::AdminController
    requires_login
    before_action :ensure_admin

    rescue_from ActiveRecord::RecordInvalid do |e|
      render json: { errors: e.record.errors.full_messages }, status: 422
    end

    # GET /admin/coin-engine/withdraw_requests.json?status=pending
    def index
      status = params[:status].to_s.presence
      scope = WithdrawRequest.recent
      scope = scope.where(status: status) if WithdrawRequest::STATUSES.include?(status)
      scope = scope.limit([params[:limit].to_i, 200].min.clamp(1, 200))

      records = scope.includes(:user, :decided_by).map { |wr| serialize(wr) }
      render json: { records: records }
    end

    # GET /admin/coin-engine/withdraw_requests/stats.json
    def stats
      counts = WithdrawRequest.group(:status).count
      render json: {
        pending:   counts['pending']   || 0,
        approved:  counts['approved']  || 0,
        rejected:  counts['rejected']  || 0,
        cancelled: counts['cancelled'] || 0,
      }
    end

    # POST /admin/coin-engine/withdraw_requests/:id/decide.json
    def decide
      wr = WithdrawRequest.find_by(id: params[:id])
      raise ::Discourse::NotFound unless wr
      return render json: { errors: ['Already decided'] }, status: 422 unless wr.pending?

      new_status = params[:status].to_s
      unless %w[approved rejected].include?(new_status)
        raise ::Discourse::InvalidParameters, 'status'
      end

      wr.update!(
        status:             new_status,
        admin_note:         params[:admin_note].to_s.strip[0, 1000].presence,
        decided_by_user_id: current_user.id,
        decided_at:         Time.zone.now,
      )

      notify_user(wr)
      render json: { ok: true, request: serialize(wr) }
    end

    private

    def serialize(wr)
      u = wr.user
      d = wr.decided_by
      {
        id:             wr.id,
        amount:         wr.amount,
        status:         wr.status,
        wallet_address: wr.wallet_address,
        user_note:      wr.user_note,
        admin_note:     wr.admin_note,
        created_at:     wr.created_at,
        decided_at:     wr.decided_at,
        user: u ? {
          id:          u.id,
          username:    u.username,
          trust_level: u.trust_level,
          post_count:  u.post_count,
          created_at:  u.created_at,
        } : nil,
        decided_by: d ? { id: d.id, username: d.username } : nil,
      }
    end

    def notify_user(wr)
      u = wr.user
      return unless u
      msg = wr.approved? ?
        "Your withdraw request for #{wr.amount} $RENO has been **approved**. An admin will mint to `#{wr.wallet_address}` shortly." :
        "Your withdraw request for #{wr.amount} $RENO was **declined**.#{wr.admin_note ? " Reason: #{wr.admin_note}" : ''}"

      ::PostCreator.create!(
        ::Discourse.system_user,
        title: "Withdraw request ##{wr.id} #{wr.status}",
        raw: msg,
        archetype: ::Archetype.private_message,
        target_usernames: u.username,
        skip_validations: true,
      )
    rescue StandardError => e
      Rails.logger.error("[coin_engine] notify_user failed for wr ##{wr.id}: #{e.message}")
    end
  end
end
