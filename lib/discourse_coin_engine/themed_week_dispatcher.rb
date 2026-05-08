# frozen_string_literal: true

# v0.17.0 — Themed Week reward dispatcher.
#
# How participation is detected:
#   1. Post is in the themed category (SiteSetting.coin_engine_themed_week_category_id), OR
#   2. Post raw contains the themed hashtag (case-insensitive, with or
#      without the `#` prefix). The hashtag is stored without `#` in the
#      site setting; we accept both `#hashtag` and `hashtag` in the body.
#
# Matching is a UNION (either path qualifies). Posts on the OP also
# qualify — opening a topic in the themed category is just as valuable
# as a reply.
#
# Idempotency: one row per (post_id) in coin_engine_themed_week_credits.
# Edits to a qualifying post don't re-fire the bonus. Posts that get
# moved INTO the themed category later don't trigger because the hook
# only listens to post_created.
#
# Failure mode: any rescue inside the hook MUST swallow the exception —
# we don't want a themed-week bug to block users from posting.

module DiscourseCoinEngine
  module ThemedWeekDispatcher
    module_function

    # True if the configured themed week is currently running. Falsy if
    # name is empty, no category AND no hashtag is set, or end-date is
    # in the past.
    def active?
      name = SiteSetting.coin_engine_themed_week_name.to_s.strip
      return false if name.empty?

      cat_id  = SiteSetting.coin_engine_themed_week_category_id.to_i
      hashtag = SiteSetting.coin_engine_themed_week_hashtag.to_s.strip
      return false if cat_id <= 0 && hashtag.empty?

      ends_raw = SiteSetting.coin_engine_themed_week_ends_at.to_s.strip
      if ends_raw.present?
        begin
          return false if Time.parse(ends_raw) < Time.zone.now
        rescue ArgumentError
          # malformed end-date — treat as no expiry rather than refuse
          # to credit; admin can fix the value
        end
      end
      true
    end

    # Returns nil if the post does not qualify; otherwise returns one of
    # "category", "hashtag", or "both" indicating WHICH path matched.
    # The caller can use this for ledger annotation.
    def match_kind(post)
      return nil unless post && post.respond_to?(:topic) && post.respond_to?(:raw)

      cat_id     = SiteSetting.coin_engine_themed_week_category_id.to_i
      hashtag    = SiteSetting.coin_engine_themed_week_hashtag.to_s.strip
      cat_match  = false
      hash_match = false

      if cat_id > 0 && post.topic && post.topic.category_id == cat_id
        cat_match = true
      end

      if hashtag.present?
        # case-insensitive search for either `#hashtag` or `hashtag` as a
        # word. Use \b so we don't match "kitchenweek" inside "kitchenweekly".
        # The `#` is allowed before the word; the word boundary handles the
        # trailing edge.
        re = Regexp.new('(?:^|[^A-Za-z0-9_])#?' + Regexp.escape(hashtag) + '\b', Regexp::IGNORECASE)
        hash_match = !!(post.raw.to_s =~ re)
      end

      return nil unless cat_match || hash_match
      return 'both'     if cat_match && hash_match
      return 'category' if cat_match
      'hashtag'
    end

    # Main entry. Idempotent — safe to call multiple times for the same
    # post (the unique index on post_id will reject duplicates).
    # Returns the created credit row on success, nil otherwise.
    def maybe_credit!(post, user)
      return nil unless post && user
      return nil unless post.id && user.id
      return nil unless active?

      kind = match_kind(post)
      return nil unless kind

      amount = SiteSetting.coin_engine_themed_week_bonus_per_post.to_i
      return nil if amount <= 0

      themed_name = SiteSetting.coin_engine_themed_week_name.to_s.strip
      return nil if themed_name.empty?

      # Atomic create: the unique index on post_id makes this a no-op if
      # a previous call already credited this post.
      credit = nil
      ::ActiveRecord::Base.transaction do
        credit = ::DiscourseCoinEngine::ThemedWeekCredit.create!(
          post_id:          post.id,
          user_id:          user.id,
          themed_week_name: themed_name,
          amount:           amount,
          match_kind:       kind,
        )
        # Credit the user via the canonical helper (which also writes the
        # gamification_leaderboard_scores mirror). Date is today.
        if ::DiscourseCoinEngine.respond_to?(:credit_score)
          ::DiscourseCoinEngine.credit_score(user.id, Date.today, amount)
        end
      end

      Rails.logger.info(
        "[coin_engine.themed_week] credited user=#{user.id} post=#{post.id} " \
        "kind=#{kind} amount=#{amount} theme=#{themed_name.inspect}"
      )

      # Real-time push so the user sees the bonus toast immediately.
      begin
        ::MessageBus.publish(
          "/coin-engine/credits/#{user.id}",
          {
            type: 'themed_week_bonus',
            amount: amount,
            theme: themed_name,
            kind: kind,
            post_id: post.id,
            note: "Themed Week bonus: #{themed_name}",
          },
          user_ids: [user.id],
        )
      rescue StandardError => e
        Rails.logger.warn("[coin_engine.themed_week] MessageBus publish failed: #{e.message[0,160]}")
      end

      credit
    rescue ::ActiveRecord::RecordNotUnique
      # Already credited — perfectly fine, this is the dedupe path.
      nil
    rescue StandardError => e
      Rails.logger.warn(
        "[coin_engine.themed_week] credit failed user=#{user&.id} post=#{post&.id}: " \
        "#{e.class}: #{e.message[0,200]}"
      )
      nil
    end
  end
end
