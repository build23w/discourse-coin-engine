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
      RateLimiter.new(current_user, 'ce_gov_vote', 30, 1.hour).performed!
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

    # POST /coin-engine/governance/verified_pro/apply.json
    # v0.10.1 — anti-spam guards (account age, TL, post count, reapply cooldown).
    # v0.10.2 — added Discourse RateLimiter to prevent admin-PM-spam DoS.
    def apply_verified_pro
      raise Discourse::InvalidAccess unless current_user

      # 5 applications per user per hour (covers both new and resubmissions).
      # If exceeded, RateLimiter raises and Discourse returns 429.
      RateLimiter.new(current_user, "verified_pro_apply", 5, 1.hour).performed!

      company = params[:company_name].to_s.strip
      lic_num = params[:license_number].to_s.strip
      lic_st  = params[:license_state].to_s.strip
      return render_json_error('company_name required',   status: 422) if company.length < 2
      return render_json_error('license_number required', status: 422) if lic_num.length < 3
      return render_json_error('license_state required',  status: 422) if lic_st.empty?

      min_age_days = (SiteSetting.coin_engine_verified_pro_min_account_age_days rescue 7).to_i
      min_tl       = (SiteSetting.coin_engine_verified_pro_min_trust_level     rescue 2).to_i
      min_posts    = (SiteSetting.coin_engine_verified_pro_min_posts           rescue 5).to_i
      reapply_days = (SiteSetting.coin_engine_verified_pro_reapply_cooldown_days rescue 30).to_i

      if current_user.created_at > min_age_days.days.ago
        return render_json_error("Account must be at least #{min_age_days} days old to apply", status: 422)
      end
      if current_user.trust_level < min_tl
        return render_json_error("Reach trust level #{min_tl} before applying", status: 422)
      end
      if current_user.post_count.to_i < min_posts
        return render_json_error("Make at least #{min_posts} posts before applying", status: 422)
      end

      existing = VerifiedPro.find_by(user_id: current_user.id)
      if existing
        case existing.verification_status
        when 'pending'
          return render_json_error('Please wait before resubmitting (1/hour)', status: 429) if existing.updated_at > 1.hour.ago
        when 'verified'
          return render_json_error('You are already a Verified Pro', status: 422)
        when 'rejected'
          if existing.updated_at > reapply_days.days.ago
            ends_at = (existing.updated_at + reapply_days.days).strftime('%Y-%m-%d')
            return render_json_error("You can reapply after #{ends_at}", status: 429)
          end
        when 'revoked'
          return render_json_error('Your status was revoked. Please contact staff.', status: 422)
        end
      end

      vp = existing || VerifiedPro.new(user_id: current_user.id)
      vp.assign_attributes(
        company_name:        company[0, 200],
        license_number:      lic_num[0, 100],
        license_state:       lic_st[0, 50],
        note:                params[:note].to_s[0, 2000],
        verification_status: 'pending',
      )
      vp.save!

      begin
        admins = ::User.where(admin: true, active: true).pluck(:username)
        if admins.any?
          ::PostCreator.create!(
            ::Discourse.system_user,
            title: "🆕 Verified Pro application: #{company}",
            raw: "@#{current_user.username} just applied as **#{company}** (license #{lic_num}, #{lic_st}).\n\n[Review →](/admin/coin-engine#verified_pros)",
            archetype: ::Archetype.private_message,
            target_usernames: admins.first(10).join(','),
            skip_validations: true,
          )
        end
      rescue StandardError => e
        Rails.logger.warn("[coin_engine] verified_pro admin PM failed: #{e.message}")
      end

      render json: { id: vp.id, status: vp.verification_status, message: 'Application submitted. Admins typically review within 48 hours.' }
    end

    # GET /coin-engine/governance/verified_pro/:username.json (public)
    def verified_pro_lookup
      user = ::User.find_by(username_lower: params[:username].to_s.downcase)
      return render_json_error('user not found', status: 404) unless user
      vp = VerifiedPro.find_by(user_id: user.id)
      render json: vp && vp.verification_status == 'verified' ? { verified: true, company_name: vp.company_name, verified_at: vp.verified_at } : { verified: false }
    end

    # POST /coin-engine/governance/verified_pro/:user_id/decision.json { status, note? } (admin only)
    # LEGACY: prefer the admin tab at /admin/coin-engine#verified_pros which uses
    # AdminVerifiedProsController and applies the full on-approval cascade.
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
