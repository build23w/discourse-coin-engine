# frozen_string_literal: true

# Phase 3 — Social: Squads, Mentorships, Spotlight.
module DiscourseCoinEngine
  class SocialController < ::ApplicationController
    requires_login except: [:list_squads, :show_squad, :list_spotlights]


    # GET /coin-engine/social/squads.json
    def list_squads
      squads = Squad.enabled.order(total_score: :desc, member_count: :desc).limit(50).to_a
      my_squad_id = current_user && SquadMembership.where(user_id: current_user.id).limit(1).pluck(:squad_id).first
      render json: {
        squads: squads.each_with_index.map { |s, i| serialize_squad(s).merge(rank: i + 1, joined: s.id == my_squad_id) },
        my_squad_id: my_squad_id,
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

    # GET /coin-engine/social/squads/:slug.json
    def show_squad
      squad = Squad.enabled.find_by(slug: params[:slug])
      return render_json_error('squad not found', status: 404) unless squad
      members = SquadMembership.where(squad_id: squad.id).limit(100).pluck(:user_id, :role, :joined_at)
      member_users = ::User.where(id: members.map(&:first)).select(:id, :username, :name)
      member_data = members.map do |id, role, joined|
        u = member_users.detect { |x| x.id == id }
        u && { username: u.username, name: u.name, role: role, joined_at: joined }
      end.compact
      render json: { squad: serialize_squad(squad).merge(members: member_data) }
    end

    # POST /coin-engine/social/squads/:slug/join.json
    def join_squad
      squad = Squad.enabled.find_by(slug: params[:slug])
      return render_json_error('squad not found', status: 404) unless squad
      existing = SquadMembership.find_by(user_id: current_user.id)
      return render_json_error('already in a squad') if existing
      m = SquadMembership.create!(squad_id: squad.id, user_id: current_user.id, role: 'member', joined_at: Time.now)
      squad.increment!(:member_count)
      render json: { membership_id: m.id, squad: squad.slug }
    end

    # POST /coin-engine/social/squads/leave.json
    def leave_squad
      m = SquadMembership.find_by(user_id: current_user.id)
      return render_json_error('not in a squad') unless m
      Squad.where(id: m.squad_id).update_all('member_count = GREATEST(member_count - 1, 0)')
      m.destroy
      render json: { ok: true }
    end

    # POST /coin-engine/social/mentorships.json { mentee_username, note? }
    def create_mentorship
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
  end
end
