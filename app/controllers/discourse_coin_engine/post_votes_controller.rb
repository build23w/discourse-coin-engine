# frozen_string_literal: true
require 'digest'

# v0.30.0 — Reddit-style voting wired to $RENO, POST-centric.
# Votes target a POST: the OP (feed) or any reply (topic page). One vote per
# (user, post). Anti-abuse: TL>=N to vote, rolling rate limits (30/hr, 200/day),
# can't self-vote. Author earns $RENO only on eligible upvotes (voter TL>=1,
# account >= min_age_days, not self) under per-post + per-author DAILY caps.
# Downvotes never pay; un-voting never claws back.
module DiscourseCoinEngine
  class PostVotesController < ::ApplicationController
    requires_login except: [:batch, :top, :top_replies]
    skip_before_action :check_xhr, raise: false

    rescue_from ::Discourse::InvalidParameters do |e|
      render json: { errors: [e.message] }, status: 400
    end

    # POST /coin-engine/votes/cast.json { post_id | topic_id, direction(1|-1|0) }
    def cast
      return render_json_error('Voting is disabled.', status: 403) unless setting(:coin_engine_feed_voting_enabled, true)
      RateLimiter.new(current_user, 'coin_engine_vote_hour', 30, 1.hour).performed!
      RateLimiter.new(current_user, 'coin_engine_vote_day', 200, 24.hours).performed!

      min_tl = setting(:coin_engine_vote_reward_min_trust_level, 1).to_i
      if current_user.trust_level.to_i < min_tl && !current_user.staff?
        return render_json_error("Spend a little time on the forum (trust level #{min_tl}) before voting.", status: 403)
      end

      post = resolve_post
      return render_json_error('post not found', status: 404) unless post
      author_id = post.user_id.to_i
      return render_json_error('You cannot vote on your own post.', status: 422) if author_id == current_user.id

      raw = params[:direction].to_i
      dir = raw > 0 ? 1 : (raw < 0 ? -1 : 0)

      reward_grant = 0
      final_dir = 0
      ::ActiveRecord::Base.transaction do
        existing = PostVote.lock.find_by(user_id: current_user.id, post_id: post.id)
        if dir == 0 || (existing && existing.direction == dir)
          existing&.destroy
          final_dir = 0
        elsif existing
          existing.update!(direction: dir)
          final_dir = dir
        else
          pv = PostVote.create!(
            user_id: current_user.id, topic_id: post.topic_id, post_id: post.id,
            author_user_id: author_id, direction: dir, rewarded: false
          )
          final_dir = dir
          if dir == 1 && author_id.positive? && reward_eligible?(author_id) && under_caps?(post.id, author_id)
            reward_grant = setting(:coin_engine_vote_reward_amount, 2).to_i
            pv.update_column(:rewarded, true) if reward_grant.positive?
          end
        end
      end

      if reward_grant.positive?
        begin
          ::DiscourseCoinEngine.credit_score(author_id, Date.today, reward_grant)
          ::DiscourseCoinEngine.refresh_user_score(author_id) if ::DiscourseCoinEngine.respond_to?(:refresh_user_score)
          notify_author(author_id, post, reward_grant)
        rescue StandardError => e
          Rails.logger.warn("[coin_engine.vote] reward credit failed: #{e.class} #{e.message}")
        end
      end

      render json: {
        ok: true, post_id: post.id, topic_id: post.topic_id,
        score: PostVote.score_for_post(post.id), my_vote: final_dir, rewarded: reward_grant
      }
    rescue RateLimiter::LimitExceeded => e
      render_json_error("Whoa, slow down — try again in #{e.available_in}s.", status: 429)
    end

    # GET /coin-engine/votes/batch.json
    #   ?post_ids=1,2,3   -> per-post scores (topic page)
    #   ?topic_ids=1,2,3  -> each topic's OP post score (feed)
    def batch
      enabled = !!setting(:coin_engine_feed_voting_enabled, true)
      if params[:post_ids].present?
        ids = parse_ids(params[:post_ids])
        return render json: { votes: {}, key: 'post', enabled: enabled } if ids.empty?
        # SCALE: aggregate is identical for every viewer of the same posts — cache
        # 60s keyed on the id set. Per-user my_vote merged separately below.
        rows = Discourse.cache.fetch("ce_vb_p_#{Digest::MD5.hexdigest(ids.sort.join(','))}", expires_in: 60.seconds) do
          ::ActiveRecord::Base.connection.exec_query(
            "SELECT post_id, COALESCE(SUM(direction),0)::int AS score, COUNT(*)::int AS n " \
            "FROM coin_engine_post_votes WHERE post_id IN (#{ids.join(',')}) GROUP BY post_id"
          ).to_a
        end
        mine = current_user ? PostVote.where(user_id: current_user.id, post_id: ids).pluck(:post_id, :direction).to_h : {}
        out = {}
        rows.each { |r| out[r['post_id'].to_i] = { score: r['score'].to_i, count: r['n'].to_i, my_vote: (mine[r['post_id'].to_i] || 0) } }
        ids.each { |i| out[i] ||= { score: 0, count: 0, my_vote: (mine[i] || 0) } }
        render json: { votes: out, key: 'post', enabled: enabled }
      else
        ids = parse_ids(params[:topic_ids])
        return render json: { votes: {}, key: 'topic', enabled: enabled } if ids.empty?
        rows = Discourse.cache.fetch("ce_vb_t_#{Digest::MD5.hexdigest(ids.sort.join(','))}", expires_in: 60.seconds) do
          ::ActiveRecord::Base.connection.exec_query(<<~SQL).to_a
            SELECT t.id AS topic_id, p.id AS op_id,
                   COALESCE(SUM(v.direction),0)::int AS score, COUNT(v.id)::int AS n
            FROM topics t
            JOIN posts p ON p.topic_id = t.id AND p.post_number = 1
            LEFT JOIN coin_engine_post_votes v ON v.post_id = p.id
            WHERE t.id IN (#{ids.join(',')})
            GROUP BY t.id, p.id
          SQL
        end
        op_ids = rows.map { |r| r['op_id'].to_i }
        mine = current_user && op_ids.present? ? PostVote.where(user_id: current_user.id, post_id: op_ids).pluck(:post_id, :direction).to_h : {}
        out = {}
        rows.each { |r| out[r['topic_id'].to_i] = { score: r['score'].to_i, count: r['n'].to_i, op_id: r['op_id'].to_i, my_vote: (mine[r['op_id'].to_i] || 0) } }
        ids.each { |i| out[i] ||= { score: 0, count: 0, my_vote: 0 } }
        render json: { votes: out, key: 'topic', enabled: enabled }
      end
    end

    # GET /coin-engine/votes/top.json — most-upvoted topics (by OP score, 30d)
    def top
      rows = ::ActiveRecord::Base.connection.exec_query(<<~SQL)
        SELECT t.id AS topic_id, COALESCE(SUM(v.direction),0)::int AS score, t.title, t.slug
        FROM topics t
        JOIN posts p ON p.topic_id = t.id AND p.post_number = 1
        JOIN coin_engine_post_votes v ON v.post_id = p.id
        WHERE t.deleted_at IS NULL AND t.visible = true AND v.created_at > NOW() - INTERVAL '30 days'
        GROUP BY t.id, t.title, t.slug
        HAVING COALESCE(SUM(v.direction),0) > 0
        ORDER BY score DESC LIMIT 20
      SQL
      render json: { top: rows.map { |r| { topic_id: r['topic_id'].to_i, score: r['score'].to_i, title: r['title'], slug: r['slug'] } } }
    end

    # GET /coin-engine/votes/top_replies.json?topic_id=X&limit=3
    # Highest-upvoted REPLIES (post_number > 1) in a topic, score-desc. Powers the
    # pinned "Top reply" card so the most-upvoted reply surfaces above the stream
    # without reordering Discourse's (anchor/threading-bound) chronological posts.
    def top_replies
      enabled = !!setting(:coin_engine_feed_voting_enabled, true)
      topic_id = params[:topic_id].to_i
      return render json: { replies: [], enabled: enabled } if topic_id <= 0
      limit = params[:limit].present? ? [[params[:limit].to_i, 1].max, 10].min : 3

      # SCALE: rows + excerpts (PrettyText is the expensive part) are viewer-
      # independent — cache the base payload 60s; merge per-user my_vote after.
      base = Discourse.cache.fetch("ce_topreplies_#{topic_id}_#{limit}", expires_in: 60.seconds) do
        rows = ::ActiveRecord::Base.connection.exec_query(<<~SQL).to_a
          SELECT p.id AS post_id, p.post_number, p.user_id,
                 COALESCE(SUM(v.direction),0)::int AS score, COUNT(v.id)::int AS n
          FROM posts p
          JOIN coin_engine_post_votes v ON v.post_id = p.id
          WHERE p.topic_id = #{topic_id} AND p.post_number > 1
                AND p.deleted_at IS NULL AND COALESCE(p.hidden, false) = false
          GROUP BY p.id, p.post_number, p.user_id
          HAVING COALESCE(SUM(v.direction),0) > 0
          ORDER BY score DESC, n DESC, p.post_number ASC
          LIMIT #{limit}
        SQL
        post_ids = rows.map { |r| r['post_id'].to_i }
        if post_ids.empty?
          []
        else
          posts = ::Post.where(id: post_ids).index_by(&:id)
          users = ::User.where(id: rows.map { |r| r['user_id'].to_i }.uniq).index_by(&:id)
          topic = ::Topic.find_by(id: topic_id)
          rows.filter_map do |r|
            pid  = r['post_id'].to_i
            post = posts[pid]
            next nil unless post
            u = users[r['user_id'].to_i]
            excerpt = begin
              ::PrettyText.excerpt(post.cooked.to_s, 200, keep_emoji_images: true)
            rescue StandardError
              post.raw.to_s[0, 200]
            end
            {
              post_id: pid,
              post_number: r['post_number'].to_i,
              score: r['score'].to_i,
              count: r['n'].to_i,
              my_vote: 0,
              excerpt: excerpt,
              created_at: post.created_at,
              url: topic ? "/t/#{topic.slug}/#{topic.id}/#{r['post_number'].to_i}" : nil,
              username: u&.username,
              name: u&.name,
              avatar_template: u&.avatar_template
            }
          end
        end
      end
      return render json: { replies: [], enabled: enabled, topic_id: topic_id } if base.empty?

      replies = base
      if current_user
        mine = PostVote.where(user_id: current_user.id, post_id: base.map { |h| h[:post_id] }).pluck(:post_id, :direction).to_h
        replies = base.map { |h| (d = mine[h[:post_id]]) ? h.merge(my_vote: d) : h } if mine.any?
      end

      render json: { replies: replies, enabled: enabled, topic_id: topic_id }
    end

    private

    def parse_ids(raw)
      raw.to_s.split(',').map(&:to_i).reject { |i| i <= 0 }.first(80)
    end

    def resolve_post
      if params[:post_id].present?
        p = ::Post.find_by(id: params[:post_id].to_i)
        return nil if p.nil? || p.deleted_at
        p
      elsif params[:topic_id].present?
        t = ::Topic.find_by(id: params[:topic_id].to_i)
        return nil unless t
        ::Post.where(topic_id: t.id, post_number: 1).order(:post_number).first
      end
    end

    def setting(key, default)
      SiteSetting.respond_to?(key) ? SiteSetting.public_send(key) : default
    rescue StandardError
      default
    end

    def reward_eligible?(author_id)
      return false if author_id == current_user.id
      return false if current_user.trust_level.to_i < setting(:coin_engine_vote_reward_min_trust_level, 1).to_i
      min_age = setting(:coin_engine_vote_reward_min_account_age_days, 3).to_i
      current_user.created_at <= min_age.days.ago
    end

    def under_caps?(post_id, author_id)
      amt = setting(:coin_engine_vote_reward_amount, 2).to_i
      return false if amt <= 0
      cap_post   = setting(:coin_engine_vote_reward_daily_cap_per_topic, 50).to_i
      cap_author = setting(:coin_engine_vote_reward_daily_cap_per_author, 200).to_i
      since = Time.zone.now.beginning_of_day
      post_paid   = PostVote.where(post_id: post_id, rewarded: true).where('created_at >= ?', since).count * amt
      author_paid = PostVote.where(author_user_id: author_id, rewarded: true).where('created_at >= ?', since).count * amt
      (post_paid + amt <= cap_post) && (author_paid + amt <= cap_author)
    end

    def notify_author(author_id, post, amount)
      coin = setting(:coin_engine_coin_name, '$RENO')
      MessageBus.publish("/coin-engine/credits/#{author_id}", {
        amount: amount, reason: 'upvote_reward',
        label: "+#{amount} #{coin} — your post was upvoted",
        coin: coin, ref: { kind: 'upvote', post_id: post.id, topic_id: post.topic_id }, ts: Time.now.to_i
      }, user_ids: [author_id])
    rescue StandardError => e
      Rails.logger.warn("[coin_engine.vote] notify failed: #{e.message}")
    end
  end
end
