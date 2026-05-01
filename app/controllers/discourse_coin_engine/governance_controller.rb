# frozen_string_literal: true

# Phase 5 — Web3/Governance: DAO Votes, Verified Pro applications.
module DiscourseCoinEngine
  class GovernanceController < ::ApplicationController
    requires_login except: [:list_votes, :show_vote, :verified_pro_lookup]


    # GET /coin-engine/governance/votes.json
    def list_votes
      vs = Vote.where(status: %w[open closed]).order(starts_at: :desc).limit(20)
      render json: { votes: vs.map { |v| serialize_vote(v) } }
    end

    # GET /coin-engine/governance/votes/:slug.json
    def show_vote
      v = Vote.find_by(slug: params[:slug])
      return render_json_error('vote not found', status: 404) unless v
      tally = v.tally.to_h
      already_voted = current_user ? VoteBallot.where(vote_id: v.id, user_id: current_user.id).exists? : false
      render json: { vote: serialize_vote(v).merge(tally: tally, already_voted: already_voted) }
    end

    # POST /coin-engine/governance/votes/:slug/cast.json { option_key }
    def cast_vote
      v = Vote.find_by(slug: params[:slug])
      return render_json_error('vote not found', status: 404) unless v
      return render_json_error('vote is closed') unless v.status == 'open' && v.ends_at > Time.now
      key = params[:option_key].to_s
      return render_json_error('invalid option') unless v.parsed_options.any? { |o| (o.is_a?(Hash) ? o['key'] : o.to_s) == key }

      weight = v.weighting == 'score_weighted' ? Math.sqrt(::DiscourseCoinEngine.coin_user_total(current_user.id) || 0).to_i.clamp(1, 1000) : 1
      VoteBallot.create!(vote_id: v.id, user_id: current_user.id, option_key: key, weight: weight)
      render json: { ok: true, weight: weight }
    rescue ActiveRecord::RecordNotUnique
      render_json_error('already voted')
    end

    # POST /coin-engine/governance/verified_pro/apply.json { company_name, license_number, license_state, note? }
    def apply_verified_pro
      vp = VerifiedPro.find_by(user_id: current_user.id) ||
           VerifiedPro.new(user_id: current_user.id, verification_status: 'pending')
      vp.assign_attributes(
        company_name: params[:company_name].to_s[0, 200],
        license_number: params[:license_number].to_s[0, 100],
        license_state: params[:license_state].to_s[0, 50],
        note: params[:note].to_s[0, 2000],
        verification_status: 'pending',
      )
      vp.save!
      render json: { id: vp.id, status: vp.verification_status }
    end

    # GET /coin-engine/governance/verified_pro/:username.json (public)
    def verified_pro_lookup
      user = ::User.find_by(username_lower: params[:username].to_s.downcase)
      return render_json_error('user not found', status: 404) unless user
      vp = VerifiedPro.find_by(user_id: user.id)
      render json: vp && vp.verification_status == 'verified' ? { verified: true, company_name: vp.company_name, verified_at: vp.verified_at } : { verified: false }
    end

    # POST /coin-engine/governance/verified_pro/:user_id/decision.json { status, note? } (admin only)
    def decide_verified_pro
      raise Discourse::InvalidAccess unless current_user.admin?
      vp = VerifiedPro.find_by(user_id: params[:user_id])
      return render_json_error('not found', status: 404) unless vp
      status = params[:status].to_s
      return render_json_error('invalid status') unless %w[verified rejected revoked].include?(status)
      vp.update!(
        verification_status: status,
        verified_at: status == 'verified' ? Time.now : vp.verified_at,
        verified_by_user_id: current_user.id,
        note: params[:note].to_s[0, 2000].presence || vp.note,
      )
      render json: { id: vp.id, status: vp.verification_status }
    end

    private

    def serialize_vote(v)
      { slug: v.slug, title: v.title, description: v.description, options: v.parsed_options,
        starts_at: v.starts_at, ends_at: v.ends_at, status: v.status, weighting: v.weighting }
    end
  end
end
