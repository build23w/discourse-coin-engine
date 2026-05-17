# frozen_string_literal: true

# v0.21.0 — Admin surface for the stake-yield distribution program.
#
# Endpoints (all admin-gated via Admin::AdminController):
#   GET    /admin/coin-engine/stake_distributions.json
#     list recent distributions (paginated) — for the admin UI history table
#
#   GET    /admin/coin-engine/stake_distributions/:id.json
#     show one distribution + its payout rows
#
#   POST   /admin/coin-engine/stake_distributions.json
#     body: { period_label, total_amount, notes? }
#     creates a pending distribution row + enqueues the snapshot/compute job
#
#   DELETE /admin/coin-engine/stake_distributions/:id.json
#     only allowed while status='pending' or status='failed'; cleans up an
#     errored row so it can be retried with a different period_label

module DiscourseCoinEngine
  class AdminStakeDistributionsController < ::Admin::AdminController
    requires_login
    skip_before_action :check_xhr, raise: false

    # GET /admin/coin-engine/stake_distributions.json?page=N&limit=20
    def index
      page  = [params[:page].to_i, 1].max
      limit = [[(params[:limit].presence || 20).to_i, 1].max, 100].min
      offset = (page - 1) * limit

      scope = StakeDistribution.recent
      total = scope.count
      rows  = scope.limit(limit).offset(offset).to_a

      render json: {
        items: rows.map(&:serialize_admin),
        page:  page,
        limit: limit,
        total: total,
      }
    end

    # GET /admin/coin-engine/stake_distributions/:id.json
    def show
      d = StakeDistribution.find_by(id: params[:id])
      return render json: { errors: ['not found'] }, status: 404 unless d

      payouts = StakePayout.where(distribution_id: d.id).order(payout_amount: :desc).limit(500).to_a
      users   = ::User.where(id: payouts.map(&:user_id).uniq).index_by(&:id)

      render json: {
        distribution: d.serialize_admin,
        payouts: payouts.map { |p|
          u = users[p.user_id]
          {
            id:                                p.id,
            user_id:                           p.user_id,
            username:                          u&.username || '(deleted)',
            stake_amount_lamports_at_snapshot: p.stake_amount_lamports_at_snapshot.to_i,
            payout_amount:                     p.payout_amount.to_i,
            status:                            p.status,
            claimed_at:                        p.claimed_at,
            created_at:                        p.created_at,
          }
        },
      }
    end

    # POST /admin/coin-engine/stake_distributions.json
    # body: { period_label, total_amount, notes? }
    def create
      period = params[:period_label].to_s.strip
      total  = params[:total_amount].to_i
      notes  = params[:notes].to_s

      return render json: { errors: ['period_label required'] }, status: 422 if period.empty?
      return render json: { errors: ['period_label too long (max 60 chars)'] }, status: 422 if period.length > 60
      return render json: { errors: ['total_amount must be a positive integer'] }, status: 422 if total <= 0

      # Defense-in-depth: hard cap per distribution. A misconfigured admin tool
      # shouldn't be able to drain the reserve in one click.
      max_per_dist = (SiteSetting.coin_engine_max_airdrop_amount rescue 1_000_000).to_i
      if total > max_per_dist
        return render json: { errors: ["total_amount exceeds max single distribution (#{max_per_dist})"] }, status: 422
      end

      if StakeDistribution.exists?(period_label: period)
        return render json: { errors: ["period_label '#{period}' already exists"] }, status: 409
      end

      d = StakeDistribution.create!(
        period_label:  period,
        total_amount:  total,
        status:        'pending',
        admin_user_id: current_user.id,
        notes:         notes[0, 4000],
      )

      # Background job does the snapshot + share computation + payout-row inserts.
      # Lives in app/jobs/regular/coin_engine_disperse_stake_distribution.rb.
      Jobs.enqueue(:coin_engine_disperse_stake_distribution, distribution_id: d.id)

      render json: { ok: true, distribution: d.serialize_admin }, status: 201
    rescue ActiveRecord::RecordInvalid => e
      render json: { errors: e.record.errors.full_messages }, status: 422
    rescue StandardError => e
      Rails.logger.warn "[coin-engine] admin stake distribution create failed: #{e.class}: #{e.message}"
      render json: { errors: ["#{e.class}: #{e.message[0,200]}"] }, status: 500
    end

    # DELETE /admin/coin-engine/stake_distributions/:id.json
    # Only removable while pending or failed. Completed/computed rows are
    # historical record and cannot be deleted via this endpoint.
    def destroy
      d = StakeDistribution.find_by(id: params[:id])
      return render json: { errors: ['not found'] }, status: 404 unless d
      unless %w[pending failed].include?(d.status)
        return render json: { errors: ["cannot delete distribution in status '#{d.status}'"] }, status: 422
      end
      d.destroy!
      render json: { ok: true }
    end
  end
end
