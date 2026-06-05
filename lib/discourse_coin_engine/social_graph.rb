# frozen_string_literal: true
module DiscourseCoinEngine
  # One-way follows + reposts ("share to my profile"), plus the DEDUPED followed
  # feed. Core protection: each shared item (kind,ref_id) appears at most ONCE in
  # a user's followed feed no matter how many people they follow reposted it, and
  # no single reposter can flood a page (per-author cap). Everything is a couple
  # of indexed SQL queries -- no N+1, no per-follow fan-out.
  module SocialGraph
    module_function

    FEED_WINDOW_DAYS = 30
    PER_AUTHOR_CAP   = 3   # max items from one reposter per feed page

    # ---- follows ----
    def following_ids(uid)
      return [] unless uid
      Discourse.cache.fetch("ce_following_#{uid}", expires_in: 2.minutes) do
        Follow.where(follower_id: uid).pluck(:following_id)
      end
    end

    def bust_follow_cache(uid)
      Discourse.cache.delete("ce_following_#{uid}")
    end

    def following?(follower_id, following_id)
      Follow.exists?(follower_id: follower_id, following_id: following_id)
    end

    def follow!(follower, following_id)
      return false if follower.id == following_id.to_i
      return false unless ::User.exists?(id: following_id)
      Follow.create!(follower_id: follower.id, following_id: following_id)
      bust_follow_cache(follower.id)
      true
    rescue ActiveRecord::RecordNotUnique
      true
    end

    def unfollow!(follower, following_id)
      Follow.where(follower_id: follower.id, following_id: following_id).delete_all
      bust_follow_cache(follower.id)
      false
    end

    def followers_count(uid); Follow.where(following_id: uid).count; end
    def following_count(uid); Follow.where(follower_id: uid).count; end

    # ---- reposts ----
    def reposted?(uid, kind, ref_id)
      Repost.exists?(user_id: uid, kind: kind, ref_id: ref_id)
    end

    def repost!(user, kind, ref_id, caption = nil)
      Repost.create!(user_id: user.id, kind: kind, ref_id: ref_id.to_i, caption: caption.to_s[0, 280].presence)
      true
    rescue ActiveRecord::RecordNotUnique
      true
    end

    def unrepost!(user, kind, ref_id)
      Repost.where(user_id: user.id, kind: kind, ref_id: ref_id).delete_all
      false
    end

    def repost_count(kind, ref_id); Repost.where(kind: kind, ref_id: ref_id).count; end

    # ---- follower / following lists ----
    def users_payload(ids, viewer_id)
      return [] if ids.empty?
      mine = viewer_id ? Follow.where(follower_id: viewer_id, following_id: ids).pluck(:following_id).to_set : Set.new
      by_id = ::User.where(id: ids).index_by(&:id)
      ids.filter_map do |id|
        u = by_id[id]; next nil unless u
        { username: u.username, name: u.name, avatar_template: u.avatar_template,
          path: "/u/#{u.username}", is_following: mine.include?(u.id) }
      end
    end

    def followers_list(uid, viewer_id, limit = 200)
      ids = Follow.where(following_id: uid).order(created_at: :desc).limit(limit).pluck(:follower_id)
      users_payload(ids, viewer_id)
    end

    def following_list(uid, viewer_id, limit = 200)
      ids = Follow.where(follower_id: uid).order(created_at: :desc).limit(limit).pluck(:following_id)
      users_payload(ids, viewer_id)
    end

    # ---- profile analytics: measurable social/content metrics ----
    def analytics(uid)
      a = { followers: followers_count(uid), following: following_count(uid),
            reposts_made: Repost.where(user_id: uid).count, reposts_received: 0,
            shorts: 0, short_likes: 0, short_views: 0, short_comments: 0, topics: 0 }
      reposts_received = 0
      if defined?(::DiscourseShorts::Short)
        sc = ::DiscourseShorts::Short.where(submitted_by_id: uid)
        sids = sc.pluck(:id)
        a[:shorts] = sids.size
        a[:short_likes] = sc.sum(:likes).to_i
        a[:short_views] = sc.sum(:views).to_i
        a[:short_comments] = sc.sum(:comment_count).to_i
        reposts_received += Repost.where(kind: "short", ref_id: sids).count if sids.any?
      end
      tids = ::Topic.where(user_id: uid, deleted_at: nil).limit(5000).pluck(:id)
      a[:topics] = tids.size
      reposts_received += Repost.where(kind: "topic", ref_id: tids).count if tids.any?
      a[:reposts_received] = reposts_received
      a
    end

    # ---- DEDUPED followed feed ----
    # Returns up to `limit` cards, each a distinct shared item, newest first,
    # capped per reposter. `before` = unix ts cursor for pagination.
    def following_feed(uid, limit: 20, before: nil)
      followees = following_ids(uid)
      return { items: [], cursor: nil } if followees.empty?
      limit = [[limit.to_i, 1].max, 50].min
      before_clause = before.to_i > 0 ? "AND created_at < to_timestamp(#{before.to_i})" : ""
      ids = followees.join(",")
      # DISTINCT ON collapses duplicate reshares; outer sort/paginate by recency.
      sql = <<~SQL
        SELECT * FROM (
          SELECT DISTINCT ON (kind, ref_id)
                 id, user_id, kind, ref_id, caption, created_at
          FROM coin_engine_reposts
          WHERE user_id IN (#{ids})
            AND created_at > NOW() - INTERVAL '#{FEED_WINDOW_DAYS} days'
          ORDER BY kind, ref_id, created_at DESC
        ) t
        WHERE TRUE #{before_clause}
        ORDER BY created_at DESC
        LIMIT #{limit * 3}
      SQL
      rows = ::ActiveRecord::Base.connection.exec_query(sql).to_a

      # per-reposter cap so one prolific sharer can't dominate the page
      seen = Hash.new(0)
      capped = rows.select { |r| (seen[r["user_id"]] += 1) <= PER_AUTHOR_CAP }.first(limit)
      return { items: [], cursor: nil } if capped.empty?

      summaries = reposter_summaries(capped, followees)
      cards = resolve_cards(capped, summaries)
      { items: cards, cursor: capped.last["created_at"].to_time.to_i }
    end

    # how many of MY followees reposted each shown item (for "reposted by X +N")
    def reposter_summaries(rows, followees)
      pairs = rows.map { |r| "('#{r['kind']}',#{r['ref_id'].to_i})" }.uniq.join(",")
      return {} if pairs.empty?
      sql = <<~SQL
        SELECT kind, ref_id, COUNT(DISTINCT user_id) AS n
        FROM coin_engine_reposts
        WHERE user_id IN (#{followees.join(',')}) AND (kind, ref_id) IN (#{pairs})
        GROUP BY kind, ref_id
      SQL
      out = {}
      ::ActiveRecord::Base.connection.exec_query(sql).each { |r| out["#{r['kind']}:#{r['ref_id']}"] = r["n"].to_i }
      out
    end

    # turn repost rows into renderable cards (short or topic), batched (no N+1)
    def resolve_cards(rows, summaries)
      users = ::User.where(id: rows.map { |r| r["user_id"] }.uniq).index_by(&:id)
      short_ids = rows.select { |r| r["kind"] == "short" }.map { |r| r["ref_id"].to_i }
      topic_ids = rows.select { |r| r["kind"] == "topic" }.map { |r| r["ref_id"].to_i }
      shorts = resolve_shorts(short_ids)
      topics = resolve_topics(topic_ids)

      rows.filter_map do |r|
        target = r["kind"] == "short" ? shorts[r["ref_id"].to_i] : topics[r["ref_id"].to_i]
        next nil unless target
        by = users[r["user_id"]]
        n = summaries["#{r['kind']}:#{r['ref_id']}"].to_i
        {
          kind: r["kind"], ref_id: r["ref_id"].to_i, caption: r["caption"],
          reposted_at: r["created_at"],
          reposter: by ? { username: by.username, name: by.name, avatar_template: by.avatar_template, path: "/u/#{by.username}" } : nil,
          also_count: [n - 1, 0].max,
          target: target
        }
      end
    end

    def resolve_shorts(ids)
      return {} if ids.empty? || !defined?(::DiscourseShorts::Short)
      ::DiscourseShorts::Short.where(id: ids).index_by(&:id).transform_values do |s|
        owner = s.submitted_by_id && ::User.find_by(id: s.submitted_by_id)
        { id: s.id, video_id: s.video_id, provider: s.provider, video_url: s.video_url,
          poster_url: s.poster_url, title: s.title, likes: s.likes, comment_count: s.comment_count,
          owner: owner ? { username: owner.username, path: "/u/#{owner.username}", avatar_template: owner.avatar_template } : nil }
      end
    end

    def resolve_topics(ids)
      return {} if ids.empty?
      ::Topic.where(id: ids, deleted_at: nil).where(visible: true).index_by(&:id).transform_values do |t|
        excerpt = (t.excerpt.presence rescue nil)
        { id: t.id, title: t.title, slug: t.slug, url: "/t/#{t.slug}/#{t.id}",
          excerpt: excerpt, image_url: (t.image_url rescue nil),
          posts_count: t.posts_count, category_id: t.category_id }
      end
    end
  end
end
