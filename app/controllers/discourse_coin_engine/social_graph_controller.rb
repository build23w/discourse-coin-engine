# frozen_string_literal: true
module DiscourseCoinEngine
  # One-way follows + reposts ("share to profile") + the deduped followed feed.
  class SocialGraphController < ::ApplicationController
    requires_login except: %i[graph reposts]
    skip_before_action :check_xhr, raise: false

    rescue_from ::Discourse::InvalidParameters do |e|
      render json: { errors: [e.message] }, status: 400
    end

    # POST /coin-engine/social/follow.json { username | user_id }
    def follow
      target = lookup_user
      raise ::Discourse::InvalidParameters.new(:user) unless target
      raise ::Discourse::InvalidParameters.new(:user) if target.id == current_user.id
      if SocialGraph.following?(current_user.id, target.id)
        following = SocialGraph.unfollow!(current_user, target.id)
      else
        ::RateLimiter.new(current_user, "ce_follow", 120, 1.day).performed!
        following = SocialGraph.follow!(current_user, target.id)
      end
      render json: { ok: true, following: following, followers_count: SocialGraph.followers_count(target.id) }
    rescue ::RateLimiter::LimitExceeded => e
      render json: { ok: false, error: "Slow down — try again in #{e.available_in}s." }, status: 429
    end

    # GET /coin-engine/social/graph/:username.json
    def graph
      u = ::User.find_by(username_lower: params[:username].to_s.downcase)
      raise ::Discourse::NotFound unless u
      render json: {
        user_id: u.id, username: u.username,
        followers: SocialGraph.followers_count(u.id),
        following: SocialGraph.following_count(u.id),
        is_following: current_user ? SocialGraph.following?(current_user.id, u.id) : false,
        is_me: current_user&.id == u.id
      }
    end

    # POST /coin-engine/social/repost.json { kind, ref_id, caption? }
    def repost
      kind = params[:kind].to_s
      ref_id = params[:ref_id].to_i
      raise ::Discourse::InvalidParameters.new(:kind) unless Repost::KINDS.include?(kind)
      raise ::Discourse::InvalidParameters.new(:ref_id) if ref_id <= 0
      raise ::Discourse::InvalidParameters.new(:ref_id) unless target_exists?(kind, ref_id)

      if SocialGraph.reposted?(current_user.id, kind, ref_id)
        reposted = SocialGraph.unrepost!(current_user, kind, ref_id)
      else
        ::RateLimiter.new(current_user, "ce_repost", 60, 1.day).performed!
        reposted = SocialGraph.repost!(current_user, kind, ref_id, params[:caption])
        mirror_short_share(ref_id) if kind == "short" && reposted
      end
      render json: { ok: true, reposted: reposted, count: SocialGraph.repost_count(kind, ref_id) }
    rescue ::RateLimiter::LimitExceeded => e
      render json: { ok: false, error: "Slow down — try again in #{e.available_in}s." }, status: 429
    end

    # GET /coin-engine/social/feed.json?before=TS  (deduped followed feed)
    def feed
      data = SocialGraph.following_feed(current_user.id, limit: params[:limit], before: params[:before])
      render json: data
    end

    # GET /coin-engine/social/reposts/:username.json?before=TS  (a profile's reposts)
    def reposts
      u = ::User.find_by(username_lower: params[:username].to_s.downcase)
      raise ::Discourse::NotFound unless u
      limit = [[params[:limit].to_i, 1].max, 50].min
      limit = 20 if params[:limit].blank?
      scope = Repost.where(user_id: u.id).order(created_at: :desc)
      scope = scope.where("created_at < to_timestamp(?)", params[:before].to_i) if params[:before].to_i > 0
      rows = scope.limit(limit).map { |r| { "id" => r.id, "user_id" => r.user_id, "kind" => r.kind, "ref_id" => r.ref_id, "caption" => r.caption, "created_at" => r.created_at } }
      cards = SocialGraph.resolve_cards(rows, {})
      render json: { items: cards, cursor: (rows.last && rows.last["created_at"].to_time.to_i) }
    end

    private

    def lookup_user
      if params[:user_id].present?
        ::User.find_by(id: params[:user_id].to_i)
      elsif params[:username].present?
        ::User.find_by(username_lower: params[:username].to_s.downcase)
      end
    end

    def target_exists?(kind, ref_id)
      if kind == "short"
        defined?(::DiscourseShorts::Short) && ::DiscourseShorts::Short.exists?(id: ref_id)
      else
        ::Topic.exists?(id: ref_id, deleted_at: nil)
      end
    end

    # keep the short's own `shares` counter (used by recycler) in sync with an
    # internal repost so an internally-shared short is never recycled.
    def mirror_short_share(ref_id)
      return unless defined?(::DiscourseShorts::Short)
      ::DiscourseShorts::Short.where(id: ref_id).update_all("shares = COALESCE(shares,0) + 1")
    rescue StandardError
      nil
    end
  end
end
