# frozen_string_literal: true

# v0.10.1 — Admin UI for Verified Pro applications.
# Mounted under /admin/coin-engine/* alongside admin_payments.
#
# Endpoints:
#   GET  /admin/coin-engine/verified_pros.json?status=pending   -> list applications
#   GET  /admin/coin-engine/verified_pros/stats.json            -> counts by status
#   POST /admin/coin-engine/verified_pros/:user_id/decide.json  -> approve | reject | revoke
#                                                                 + on-approval cascade
#   POST /admin/coin-engine/verified_pros/:user_id/request_info.json -> sends DM asking for more info
#
# Security: Discourse's Admin::AdminController already enforces admin? — anyone
# else gets 403 from the framework before any code here runs.

module DiscourseCoinEngine
  class AdminVerifiedProsController < ::Admin::AdminController
    requires_plugin DiscourseCoinEngine::PLUGIN_NAME

    # GET /admin/coin-engine/verified_pros.json?status=pending&limit=50&page=1
    def index
      status = params[:status].to_s.presence || 'pending'
      status = 'pending' unless %w[pending verified rejected revoked all].include?(status)
      page   = (params[:page]  || 1).to_i.clamp(1, 1000)
      limit  = (params[:limit] || 50).to_i.clamp(1, 200)

      scope = ::DiscourseCoinEngine::VerifiedPro.order(updated_at: :desc)
      scope = scope.where(verification_status: status) unless status == 'all'
      total = scope.count
      records = scope.limit(limit).offset((page - 1) * limit).to_a

      user_ids = records.map(&:user_id) + records.map(&:verified_by_user_id).compact
      users    = ::User.where(id: user_ids.uniq).index_by(&:id)

      out = records.map do |vp|
        applicant = users[vp.user_id]
        decider   = vp.verified_by_user_id ? users[vp.verified_by_user_id] : nil
        registry_url = registry_link_for(vp.license_state.to_s)
        {
          id: vp.id,
          status: vp.verification_status,
          user: applicant ? {
            id: applicant.id, username: applicant.username, name: applicant.name,
            avatar_template: applicant.avatar_template, trust_level: applicant.trust_level,
            post_count: applicant.post_count, created_at: applicant.created_at,
            email: nil  # NEVER expose email to JS — admin can click into the user
          } : nil,
          company_name:   vp.company_name,
          license_number: vp.license_number,
          license_state:  vp.license_state,
          registry_lookup_url: registry_url,
          note:           vp.note,
          submitted_at:   vp.created_at,
          updated_at:     vp.updated_at,
          verified_at:    vp.verified_at,
          decided_by:     decider ? { username: decider.username } : nil,
        }
      end

      render json: { records: out, total: total, page: page, per_page: limit, status: status }
    end

    # GET /admin/coin-engine/verified_pros/stats.json
    def stats
      counts = ::DiscourseCoinEngine::VerifiedPro.group(:verification_status).count
      render json: {
        pending:  counts['pending'].to_i,
        verified: counts['verified'].to_i,
        rejected: counts['rejected'].to_i,
        revoked:  counts['revoked'].to_i,
        applied_this_week: ::DiscourseCoinEngine::VerifiedPro.where('created_at > ?', 7.days.ago).count,
        decided_this_week: ::DiscourseCoinEngine::VerifiedPro.where('verified_at > ? OR (verification_status IN (?) AND updated_at > ?)', 7.days.ago, %w[rejected revoked], 7.days.ago).count,
      }
    end

    # POST /admin/coin-engine/verified_pros/:user_id/decide.json
    # body: { status: 'verified'|'rejected'|'revoked', note?: 'reason for the decision' }
    def decide
      vp = ::DiscourseCoinEngine::VerifiedPro.find_by(user_id: params[:user_id])
      return render(json: { errors: ['application not found'] }, status: 404) unless vp
      status = params[:status].to_s
      unless %w[verified rejected revoked].include?(status)
        return render(json: { errors: ['invalid status'] }, status: 422)
      end

      user = ::User.find_by(id: vp.user_id)
      return render(json: { errors: ['user not found'] }, status: 404) unless user

      previous_status = vp.verification_status
      ActiveRecord::Base.transaction do
        vp.update!(
          verification_status: status,
          verified_at:         status == 'verified' ? Time.now : vp.verified_at,
          verified_by_user_id: current_user.id,
          note:                params[:note].to_s[0, 2000].presence || vp.note,
        )
      end

      # On approval: cascade effects (title + bonus + DM + push). On reject/revoke
      # we only DM with reason. All best-effort — never block the decision row.
      results = { decision_recorded: true }
      begin
        if status == 'verified' && previous_status != 'verified'
          results.merge!(apply_approval_cascade!(user, vp))
        elsif status == 'rejected'
          send_decision_pm(user, vp, status, params[:note].to_s.presence)
          results[:pm_sent] = true
        elsif status == 'revoked'
          revoke_title!(user)
          send_decision_pm(user, vp, status, params[:note].to_s.presence)
          results[:title_revoked] = true
          results[:pm_sent] = true
        end
      rescue StandardError => e
        Rails.logger.error("[coin_engine] verified_pro cascade failed: #{e.class}: #{e.message}")
        results[:cascade_error] = e.message
      end

      render json: { id: vp.id, status: vp.verification_status, results: results }
    end

    # POST /admin/coin-engine/verified_pros/:user_id/request_info.json
    # body: { message: 'Please reply with a photo of your license' }
    def request_info
      vp = ::DiscourseCoinEngine::VerifiedPro.find_by(user_id: params[:user_id])
      return render(json: { errors: ['application not found'] }, status: 404) unless vp
      user = ::User.find_by(id: vp.user_id)
      return render(json: { errors: ['user not found'] }, status: 404) unless user

      msg = params[:message].to_s.strip
      return render(json: { errors: ['message required'] }, status: 422) if msg.empty?

      title = "📋 More info needed for your Verified Pro application"
      body = +"Hi @#{user.username},\n\n"
      body << "An admin reviewed your **Verified Pro** application and needs more information before deciding:\n\n"
      body << "> #{msg.gsub("\n", "\n> ")}\n\n"
      body << "Please reply on this thread with the requested info. Your application is still in the queue.\n\n"
      body << "— LF Builders Team\n"

      ::PostCreator.create!(
        ::Discourse.system_user,
        title: title, raw: body,
        archetype: ::Archetype.private_message,
        target_usernames: user.username,
        skip_validations: true,
      )
      vp.update!(note: "[admin info request #{Time.now.iso8601}] #{msg}\n\n#{vp.note}")

      render json: { ok: true }
    end

    private

    def apply_approval_cascade!(user, vp)
      results = {}

      # 1. Set the user's title — this is the main visible win, shows on every post.
      title_str = vp.company_name.to_s.strip.length > 0 ? "Verified Pro · #{vp.company_name}" : 'Verified Pro'
      title_str = title_str[0, 100]
      user.update_columns(title: title_str)
      results[:title_set] = title_str

      # 2. Grant the Verified Pro badge if it exists.
      begin
        badge_name = (SiteSetting.coin_engine_verified_pro_badge_name rescue 'Verified Pro')
        badge = ::Badge.find_by(name: badge_name)
        if badge
          ::BadgeGranter.grant(badge, user) unless ::UserBadge.exists?(user_id: user.id, badge_id: badge.id)
          results[:badge_granted] = badge.name
        end
      rescue StandardError => e
        Rails.logger.warn("[coin_engine] badge grant failed: #{e.message}")
      end

      # 3. Sign-up bonus $RENO — configurable.
      bonus = (SiteSetting.coin_engine_verified_pro_bonus_reno rescue 5000).to_i
      if bonus > 0
        ::DiscourseCoinEngine.credit_score(user.id, Date.today, bonus)
        ::DiscourseCoinEngine.refresh_user_score(user.id)
        results[:bonus_reno] = bonus
        # MessageBus push — FAB lights up immediately.
        begin
          MessageBus.publish("/coin-engine/credits/#{user.id}", {
            amount: bonus, reason: 'verified_pro_bonus',
            label: 'Verified Pro Bonus', coin: SiteSetting.coin_engine_coin_name,
            new_total: ::DiscourseCoinEngine.coin_user_total(user.id),
            note: "Welcome to Verified Pros, #{vp.company_name}!",
            ref: { type: 'verified_pro', id: vp.id }, ts: Time.now.to_i,
          }, user_ids: [user.id])
        rescue StandardError
          nil
        end
      end

      # 4. PM the user. Discourse routes the PM to email per their prefs.
      send_decision_pm(user, vp, 'verified', nil, bonus: bonus)
      results[:pm_sent] = true

      results
    end

    def revoke_title!(user)
      user.update_columns(title: nil) if user.title.to_s.start_with?('Verified Pro')
      begin
        badge_name = (SiteSetting.coin_engine_verified_pro_badge_name rescue 'Verified Pro')
        badge = ::Badge.find_by(name: badge_name)
        if badge
          ::UserBadge.where(user_id: user.id, badge_id: badge.id).destroy_all
        end
      rescue StandardError
        nil
      end
    end

    def send_decision_pm(user, vp, decision, note, bonus: 0)
      return unless user
      coin = SiteSetting.coin_engine_coin_name

      title, body = case decision
      when 'verified'
        title = "🎖 You're a Verified Pro on #{SiteSetting.title}"
        body  = +"@#{user.username},\n\n"
        body  << "Your Verified Pro application for **#{vp.company_name}** has been approved.\n\n"
        body  << "**What changed:**\n"
        body  << "- Your title is now **Verified Pro · #{vp.company_name}** — shows on every post you make\n"
        body  << "- You earned the **Verified Pro** badge\n"
        body  << "- A welcome bonus of **#{bonus} #{coin}** has been credited to your balance\n" if bonus > 0
        body  << "- You're now eligible for priority bounty invitations\n\n"
        body  << "Thank you for being part of the trades community here. Keep posting helpful answers — your verified status amplifies their trust signal for homeowners who land on your replies via search.\n\n"
        body  << "— LF Builders Team\n"
        [title, body]
      when 'rejected'
        title = "About your Verified Pro application"
        body  = +"@#{user.username},\n\n"
        body  << "After review, we weren't able to verify the credentials submitted for **#{vp.company_name}**.\n\n"
        body  << (note.present? ? "**Reviewer note:** #{note}\n\n" : '')
        body  << "You're welcome to apply again in 30 days, ideally with updated license information matching the public registry for your state/province.\n\n"
        body  << "— LF Builders Team\n"
        [title, body]
      when 'revoked'
        title = "Verified Pro status revoked"
        body  = +"@#{user.username},\n\n"
        body  << "Your Verified Pro status has been revoked.\n\n"
        body  << (note.present? ? "**Reason:** #{note}\n\n" : '')
        body  << "If you believe this is in error, please reply to this message and an admin will review.\n\n"
        body  << "— LF Builders Team\n"
        [title, body]
      end

      ::PostCreator.create!(
        ::Discourse.system_user,
        title: title, raw: body,
        archetype: ::Archetype.private_message,
        target_usernames: user.username,
        skip_validations: true,
      )
    rescue StandardError => e
      Rails.logger.warn("[coin_engine] verified_pro PM failed: #{e.message}")
    end

    # Public license-registry URL by state/province (best effort; admin
    # uses these to verify externally in one click).
    def registry_link_for(state)
      key = state.to_s.upcase.strip
      {
        'ON'  => 'https://www.ontario.ca/page/check-licence-status-and-complaints-trade-contractor',
        'BC'  => 'https://www.bcfsa.ca/online-services/find-licensee',
        'AB'  => 'https://www.alberta.ca/contractor-licence-search.aspx',
        'QC'  => 'https://www.rbq.gouv.qc.ca/citoyen/le-registre-des-detenteurs-de-licence/',
        'CA'  => 'https://www.cslb.ca.gov/onlineservices/checklicenseii/',
        'TX'  => 'https://www.tdlr.texas.gov/LicenseSearch/',
        'FL'  => 'https://www.myfloridalicense.com/wl11.asp',
        'NY'  => 'https://a836-acris.nyc.gov/CP/',
        'WA'  => 'https://secure.lni.wa.gov/verify/',
        'OR'  => 'https://search.ccb.state.or.us/search/',
      }[key] || "https://www.google.com/search?q=#{CGI.escape("#{state} contractor license lookup")}"
    end
  end
end
