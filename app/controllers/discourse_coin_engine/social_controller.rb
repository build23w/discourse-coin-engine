# frozen_string_literal: true

# Phase 3 — Social: Squads (incl. user-created), Mentorships, Spotlight.
module DiscourseCoinEngine
  class SocialController < ::ApplicationController
    requires_login except: [:list_squads, :show_squad, :list_spotlights]

    # GET /coin-engine/social/squads.json
    def list_squads
      squads = Squad.enabled.order(total_score: :desc, member_count: :desc).limit(100).to_a
      my_squad_id = current_user && SquadMembership.where(user_id: current_user.id).limit(1).pluck(:squad_id).first
      render json: {
        squads: squads.each_with_index.map { |s, i| serialize_squad(s).merge(rank: i + 1, joined: s.id == my_squad_id) },
        my_squad_id: my_squad_id,
        can_create: !!current_user,
      }
    end

    # GET /coin-engine/social/my_squad.json — current user's squad + standing
    def my_squad
      m = SquadMembership.find_by(user_id: current_user.id)
      return render json: { squad: nil } unless m
      squad = Squad.find_by(id: m.squad_id)
      return render json: { squad: nil } unless squad
      rank = Squad.enabled.where('total_score > ?', squad.total_score.to_i).count + 1
      render json: {
        squad: serialize_squad(squad).merge(rank: rank),
        membership: { role: m.role, joined_at: m.joined_at },
      }
    end

    # GET /coin-engine/social/squads/:slug.json — full squad detail (members + scores)
    def show_squad
      squad = Squad.enabled.find_by(slug: params[:slug])
      return render_json_error('squad not found', status: 404) unless squad
      render json: { squad: squad_detail(squad) }
    end

    # POST /coin-engine/social/squads.json — USER-created squad (creator = captain).
    # Anti-abuse: 3/day rate limit, trust_level >= 1 (or staff), one squad per
    # user, soft global cap. Slug auto-generated + de-duped.
    def create_squad
      RateLimiter.new(current_user, 'coin_engine_squad_create', 3, 24.hours).performed!
      if current_user.trust_level.to_i < 1 && !current_user.staff?
        return render_json_error('Spend a little time on the forum first, then you can start a squad.', status: 403)
      end
      return render_json_error('Leave your current squad before starting a new one.', status: 422) if SquadMembership.exists?(user_id: current_user.id)
      return render_json_error('Squad limit reached — ask a moderator to retire some inactive squads.', status: 422) if Squad.count >= 250

      name = params[:name].to_s.strip.gsub(/\s+/, ' ')[0, 60]
      return render_json_error('Give your squad a name (3-60 characters).', status: 422) if name.to_s.length < 3

      squad = nil
      ::ActiveRecord::Base.transaction do
        squad = Squad.create!(
          slug:         generate_unique_slug(params[:slug].presence || name),
          name:         name,
          region:       params[:region].to_s.strip[0, 60].presence,
          icon:         sanitize_icon(params[:icon]),
          color:        sanitize_color(params[:color]),
          description:  params[:description].to_s.strip[0, 500].presence,
          enabled:      true,
          member_count: 1,
          total_score:  0,
        )
        SquadMembership.create!(squad_id: squad.id, user_id: current_user.id, role: 'captain', joined_at: Time.now)
      end
      DiscourseCoinEngine::SquadHq.ensure_hq!(squad)
      render json: { squad: serialize_squad(squad).merge(rank: nil, joined: true, my_role: 'captain') }
    rescue RateLimiter::LimitExceeded => e
      render_json_error("Slow down - try again in #{e.available_in}s.", status: 429)
    rescue ActiveRecord::RecordInvalid => e
      render_json_error(e.record.errors.full_messages.join(', '), status: 422)
    end

    # PUT /coin-engine/social/squads/:slug.json — captain (or staff) edits cosmetics
    def update_squad
      RateLimiter.new(current_user, 'ce_squad_update', 20, 1.day).performed!
      squad = Squad.find_by(slug: params[:slug])
      return render_json_error('squad not found', status: 404) unless squad
      m = SquadMembership.find_by(squad_id: squad.id, user_id: current_user.id)
      unless (m && m.role == 'captain') || current_user.staff?
        return render_json_error('Only the squad captain can edit this squad.', status: 403)
      end
      squad.description = params[:description].to_s.strip[0, 500] if params.key?(:description)
      squad.region      = params[:region].to_s.strip[0, 60]      if params.key?(:region)
      squad.icon        = sanitize_icon(params[:icon])           if params.key?(:icon)
      squad.color       = sanitize_color(params[:color])         if params.key?(:color)
      squad.save!
      render json: { squad: squad_detail(squad) }
    rescue ActiveRecord::RecordInvalid => e
      render_json_error(e.record.errors.full_messages.join(', '), status: 422)
    end

    # POST /coin-engine/social/squads/:slug/join.json
    def join_squad
      RateLimiter.new(current_user, 'ce_squad_join', 20, 1.day).performed!
      squad = Squad.enabled.find_by(slug: params[:slug])
      return render_json_error('squad not found', status: 404) unless squad
      return render_json_error('You are already in a squad - leave it first.') if SquadMembership.exists?(user_id: current_user.id)
      m = SquadMembership.create!(squad_id: squad.id, user_id: current_user.id, role: 'member', joined_at: Time.now)
      squad.increment!(:member_count)
      DiscourseCoinEngine::SquadHq.ensure_hq!(squad)        # creates HQ at threshold (backfills group)
      DiscourseCoinEngine::SquadHq.sync_member!(squad, current_user, :add)
      render json: { membership_id: m.id, squad: squad.slug }
    rescue ActiveRecord::RecordNotUnique
      render_json_error('You are already in this squad.')
    end

    # POST /coin-engine/social/squads/leave.json
    def leave_squad
      RateLimiter.new(current_user, 'ce_squad_leave', 20, 1.day).performed!
      m = SquadMembership.find_by(user_id: current_user.id)
      return render_json_error('not in a squad') unless m
      squad_id = m.squad_id
      was_captain = m.role == 'captain'
      m.destroy
      Squad.where(id: squad_id).update_all('member_count = GREATEST(member_count - 1, 0)')
      if (sq = Squad.find_by(id: squad_id))
        DiscourseCoinEngine::SquadHq.sync_member!(sq, current_user, :remove)
      end
      # Hand the captaincy to the longest-tenured remaining member so a squad
      # is never left leaderless after its captain departs.
      if was_captain
        heir = SquadMembership.where(squad_id: squad_id).order(joined_at: :asc).first
        heir&.update!(role: 'captain')
      end
      render json: { ok: true }
    end

    # POST /coin-engine/social/mentorships.json { mentee_username, note? }
    def create_mentorship
      RateLimiter.new(current_user, 'ce_mentor_create', 10, 1.day).performed!
      mentee = ::User.find_by(username_lower: params[:mentee_username].to_s.downcase)
      return render_json_error('mentee not found', status: 404) unless mentee
      return render_json_error('cannot mentor yourself') if mentee.id == current_user.id
      m = Mentorship.create!(
        mentor_user_id: current_user.id,
        mentee_user_id: mentee.id,
        status: 'pending',
        note: params[:note].to_s[0, 1000],
      )
      render json: { id: m.id, mentee: mentee.username, status: 'pending' }
    rescue ActiveRecord::RecordInvalid => e
      render_json_error(e.record.errors.full_messages.join(', '))
    end

    # POST /coin-engine/social/mentorships/:id/accept.json
    def accept_mentorship
      RateLimiter.new(current_user, 'ce_mentor_accept', 30, 1.day).performed!
      m = Mentorship.find_by(id: params[:id])
      return render_json_error('mentorship not found', status: 404) unless m
      return render_json_error('only mentee can accept', status: 403) unless m.mentee_user_id == current_user.id
      m.update!(status: 'active', started_at: Time.now)
      render json: { id: m.id, status: 'active' }
    end

    # GET /coin-engine/social/spotlights.json — recent spotlight features
    def list_spotlights
      spots = Spotlight.order(featured_at: :desc).limit(20)
      render json: {
        spotlights: spots.map do |s|
          { user: ::User.where(id: s.user_id).pluck(:username).first, post_id: s.post_id,
            topic_id: s.topic_id, reason: s.reason, reward: s.reward, featured_at: s.featured_at }
        end,
      }
    end

    private

    def serialize_squad(s)
      { slug: s.slug, name: s.name, region: s.region, icon: s.icon, color: s.color,
        description: s.description, member_count: s.member_count, total_score: s.total_score }
    end

    # Full detail payload for the squad page / detail view: members with scores
    # + avatars (sorted high->low), the squad's board rank, and the viewer's role.
    def squad_detail(squad)
      memberships = SquadMembership.where(squad_id: squad.id).limit(200).pluck(:user_id, :role, :joined_at)
      uids = memberships.map(&:first)
      users = ::User.where(id: uids).select(:id, :username, :name, :uploaded_avatar_id)
      totals = ::DiscourseCoinEngine.coin_user_total_bulk(uids)
      members = memberships.map do |id, role, joined|
        u = users.detect { |x| x.id == id }
        next nil unless u
        { username: u.username, name: u.name, role: role, joined_at: joined,
          score: (totals[id] || 0).to_i, avatar_template: u.avatar_template }
      end.compact.sort_by { |x| -x[:score] }
      rank = Squad.enabled.where('total_score > ?', squad.total_score.to_i).count + 1
      mine = current_user ? SquadMembership.where(squad_id: squad.id, user_id: current_user.id).pluck(:role).first : nil
      serialize_squad(squad).merge(rank: rank, members: members, joined: !mine.nil?, my_role: mine)
    end

    def generate_unique_slug(raw)
      base = raw.to_s.strip.downcase.gsub(/[^a-z0-9]+/, '-').gsub(/\A-+|-+\z/, '')[0, 50]
      base = 'squad' if base.empty?
      slug = base
      i = 1
      while Squad.exists?(slug: slug)
        i += 1
        slug = "#{base}-#{i}"
      end
      slug
    end

    def sanitize_icon(raw)
      s = raw.to_s.strip
      s.empty? ? "\u{1F3D8}" : s[0, 8]
    end

    def sanitize_color(raw)
      s = raw.to_s.strip
      s.match?(/\A#[0-9a-fA-F]{6}\z/) ? s : '#4f46e5'
    end
  end
end
