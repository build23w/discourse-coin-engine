# frozen_string_literal: true

# v0.28.0 — Reddit-style feed voting wired to the $RENO economy.
#
# Abuse model (why this is hard to game):
#  - Only trust_level >= N (default 1) may vote at all → throwaway TL0 accounts can't.
#  - Rolling rate limits (30/hr, 200/day) instead of a rigid cooldown.
#  - One vote per (user, topic); re-voting toggles/switches.
#  - Author earns $RENO ONLY from "eligible" upvotes: voter is TL>=1, account
#    older than min_age_days (default 3), and not the author. Plus per-topic and
#    per-author DAILY caps. Downvotes never pay; un-voting never claws back.
module DiscourseCoinEngine
  class PostVotesController < ::ApplicationController
    requires_login except: [:batch, :top]
    skip_before_action :check_xhr, raise: false

    rescue_from ::Discourse::InvalidParameters do |e|
      render json: { errors: [e.message] }, status: 400
    end

    # POST /coin-engine/votes/cast.json { topic_id, direction(1|-1|0) }
    def cast
      return render_json_error('Feed voting is disabled.', status: 403) unless setting(:coin_engine_feed_voting_enabled, true)
      RateLimiter.new(current_user, 'coin_engine_vote_hour', 30, 1.hour).performed!
      RateLimiter.new(current_user, 'coin_engine_vote_day', 200, 24.hours).performed!

      min_tl = setting(:coin_engine_vote_reward_min_trust_level, 1).to_i
      if current_user.trust_level.to_i < min_tl && !current_user.staff?
        return render_json_error("Spend a little time on the forum (trust level #{min_tl}) before voting.", status: 403)
      end

      topic = ::Topic.find_by(id: params[:topic_id].to_i)
      return render_json_error('topic not found', status: 404) unless topic
      author_id = topic.user_id.to_i
      return render_json_error('You cannot vote on your own post.', status: 422) if author_id == current_user.id

      raw = params[:direction].to_i
      dir = raw > 0 ? 1 : (raw < 0 ? -1 : 0)

      reward_grant = 0
      final_dir = 0
      ::ActiveRecord::Base.transaction do
        existing = PostVote.lock.find_by(user_id: current_user.id, topic_id: topic.id)
        if dir == 0 || (existing && existing.direction == dir)
          existing&.destroy
          final_dir = 0
        elsif existing
          existing.update!(direction: dir)
          final_dir = dir
        else
          pv = PostVote.create!(
            user_id: current_user.id, topic_id: topic.id,
            post_id: topic.first_post_id, author_user_id: author_id, direction: dir, rewarded: false
          )
          final_dir = dir
          if dir == 1 && author_id.positive? && reward_eligible?(author_id) && under_caps?(topic.id, author_id)
            reward_grant = setting(:coin_engine_vote_reward_amount, 2).to_i
            pv.update_column(:rewarded, true) if reward_grant.positive?
          end
        end
      end

      if reward_grant.positive?
        begin
          ::DiscourseCoinEngine.credit_score(author_id, Date.today, reward_grant)
          ::DiscourseCoinEngine.refresh_user_score(author_id) if ::DiscourseCoinEngine.respond_to?(:refresh_user_score)
          notify_author(author_id, topic, reward_grant)
        rescue StandardError => e
          Rails.logger.warn("[coin_engine.vote] reward credit failed: #{e.class} #{e.message}")
        end
      end

      render json: { ok: true, topic_id: topic.id, score: PostVote.score_for(topic.id), my_vote: final_dir, rewarded: reward_grant }
    rescue RateLimiter::LimitExceeded => e
      render_json_error("Whoa, slow down — try again in #{e.available_in}s.", status: 429)
    end

    # GET /coin-engine/votes/batch.json?topic_ids=1,2,3  (public; my_vote=0 for anon)
    def batch
      ids = params[:topic_ids].to_s.split(',').map(&:to_i).reject { |i| i <= 0 }.first(80)
      return render json: { votes: {} } if ids.empty?
      rows = ::ActiveRecord::Base.connection.exec_query(
        "SELECT topic_id, COALESCE(SUM(direction),0)::int AS score, COUNT(*)::int AS n " \
        "FROM coin_engine_post_votes WHERE topic_id IN (#{ids.join(',')}) GROUP BY topic_id"
      )
      mine = current_user ? PostVote.where(user_id: current_user.id, topic_id: ids).pluck(:topic_id, :direction).to_h : {}
      out = {}
      rows.each { |r| out[r['topic_id'].to_i] = { score: r['score'].to_i, count: r['n'].to_i, my_vote: (mine[r['topic_id'].to_i] || 0) } }
      ids.each { |i| out[i] ||= { score: 0, count: 0, my_vote: (mine[i] || 0) } }
      render json: { votes: out, enabled: !!setting(:coin_engine_feed_voting_enabled, true) }
    end

    # GET /coin-engine/votes/top.json — most-upvoted topics (last 30 days)
    def top
      rows = ::ActiveRecord::Base.connection.exec_query(<<~SQL)
        SELECT v.topic_id, COALESCE(SUM(v.direction),0)::int AS score, t.title, t.slug
        FROM coin_engine_post_votes v
        JOIN topics t ON t.id = v.topic_id
        WHERE t.deleted_at IS NULL AND t.visible = true AND v.created_at > NOW() - INTERVAL '30 days'
        GROUP BY v.topic_id, t.title, t.slug
        HAVING COALESCE(SUM(v.direction),0) > 0
        ORDER BY score DESC LIMIT 20
      SQL
      render json: { top: rows.map { |r| { topic_id: r['topic_id'].to_i, score: r['score'].to_i, title: r['title'], slug: r['slug'] } } }
    end

    private

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

    def under_caps?(topic_id, author_id)
      amt = setting(:coin_engine_vote_reward_amount, 2).to_i
      return false if amt <= 0
      cap_topic  = setting(:coin_engine_vote_reward_daily_cap_per_topic, 50).to_i
      cap_author = setting(:coin_engine_vote_reward_daily_cap_per_author, 200).to_i
      since = Time.zone.now.beginning_of_day
      topic_paid  = PostVote.where(topic_id: topic_id, rewarded: true).where('created_at >= ?', since).count * amt
      author_paid = PostVote.where(author_user_id: author_id, rewarded: true).where('created_at >= ?', since).count * amt
      (topic_paid + amt <= cap_topic) && (author_paid + amt <= cap_author)
    end

    def notify_author(author_id, topic, amount)
      coin = setting(:coin_engine_coin_name, '$RENO')
      MessageBus.publish("/coin-engine/credits/#{author_id}", {
        amount: amount, reason: 'upvote_reward',
        label: "+#{amount} #{coin} — your post was upvoted",
        coin: coin, ref: { kind: 'upvote', topic_id: topic.id }, ts: Time.now.to_i
      }, user_ids: [author_id])
    rescue StandardError => e
      Rails.logger.warn("[coin_engine.vote] notify failed: #{e.message}")
    end
  end
end
