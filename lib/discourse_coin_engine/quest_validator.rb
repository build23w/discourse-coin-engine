# frozen_string_literal: true

# v0.20.0 Path A — Server-side quest validator. Mirrors the catalog the client widget
# tracks (in hrr-ux-pack body_tag.html) so claims can be verified against the
# actual user record before granting any reward. Trust nothing the client sends
# beyond the quest_id itself.
#
# validate(user, quest_id) -> { valid: bool, xp: int, reno: int, category: str, reason: str? }
#
# Quest categories handled:
#   - onboarding   (intro_post, set_avatar, set_bio, first_like, set_wallet, ...)
#   - reviewer     (post_count tiers)
#   - topiclord    (topic_count tiers)
#   - helper       (likes_given tiers)
#   - beloved      (likes_received tiers)
#   - explorer     (days_visited tiers)
#   - reader       (posts_read_count tiers)
#   - voyager      (topics_entered tiers)
#   - timeReader   (time_read hour tiers)
#   - builder      (trust_level tiers)
#   - reno         (gamification score tiers — no reward, holding-only)
#   - charity      (samm_* — trust client local flags, capped low)
#   - milestone    (ms_* — based on completed-quests count)

module DiscourseCoinEngine
  class QuestValidator
    # Hard caps to prevent abuse even if a quest formula misfires.
    MAX_RENO_PER_CLAIM = 50_000
    MAX_XP_PER_CLAIM   = 100_000

    class << self
      # Returns: { valid:, xp:, reno:, category:, reason? }
      def validate(user, quest_id)
        return invalid('user required')      unless user
        return invalid('quest_id required')  unless quest_id.is_a?(String) && !quest_id.empty?

        stats = user_stats(user)

        # 1. Stat-based tier quests: {category}_{stat}_{threshold}
        stat_match = quest_id.match(/\A(reviewer|topiclord|helper|beloved|explorer|reader|voyager)_([a-z_]+)_(\d+)\z/)
        if stat_match
          cat   = stat_match[1]
          field = stat_match[2]
          thr   = stat_match[3].to_i
          actual = stats[field].to_i
          return invalid("stat #{field}=#{actual} < #{thr}") if actual < thr
          return ok(cat, tier_xp(thr), tier_reno(thr))
        end

        # 2. Time-read tier: timeReader_{hours}_h  (time_read field is in seconds)
        if (m = quest_id.match(/\AtimeReader_(\d+)_h\z/))
          hours_thr = m[1].to_i
          actual_h  = stats['time_read'].to_i / 3600.0
          return invalid("time_read=#{actual_h.to_i}h < #{hours_thr}h") if actual_h < hours_thr
          return ok('timeReader', hours_thr * 10, hours_thr * 25)
        end

        # 3. Trust level: tl_N (1..4)
        if (m = quest_id.match(/\Atl_(\d+)\z/))
          thr = m[1].to_i
          return invalid("trust_level=#{user.trust_level} < #{thr}") if user.trust_level < thr
          return ok('builder', 200 * thr, 1000 * thr)
        end

        # 4. Score (holding) tier: reno_score_NNNN — informational only, no reward
        if (m = quest_id.match(/\Areno_score_(\d+)\z/))
          thr = m[1].to_i
          actual = ::DiscourseCoinEngine.coin_user_total(user.id)
          return invalid("score=#{actual} < #{thr}") if actual < thr
          return ok('reno', 0, 0)
        end

        # 5. Leaderboard rank: lb_top_N — verify by querying current rank
        if (m = quest_id.match(/\Alb_top_(\d+)\z/))
          thr = m[1].to_i
          rank = current_user_rank(user.id)
          return invalid("rank=#{rank.inspect} > #{thr}") if rank.nil? || rank > thr
          return ok('leaderboard', 0, 0)
        end

        # 6. Specific onboarding quests
        case quest_id
        when 'intro_post'
          return user.post_count >= 1 ? ok('onboarding', 50, 200) : invalid("post_count=#{user.post_count} < 1")
        when 'set_avatar'
          tmpl = user.avatar_template.to_s
          return tmpl.exclude?('letter_avatar') && !tmpl.empty? ? ok('onboarding', 50, 100) : invalid('default avatar')
        when 'set_bio'
          bio = (user.user_profile&.bio_raw || '').to_s.strip
          return bio.length > 0 ? ok('onboarding', 50, 100) : invalid('empty bio')
        when 'first_like'
          return stats['likes_given'].to_i >= 1 ? ok('onboarding', 25, 50) : invalid('no likes given')
        when 'set_wallet'
          return wallet_set?(user) ? ok('onboarding', 100, 500) : invalid('no wallet linked')
        when 'first_topic_entered'
          return stats['topics_entered'].to_i >= 1 ? ok('onboarding', 10, 25) : invalid('no topics entered')
        when 'first_post_read'
          return stats['posts_read_count'].to_i >= 10 ? ok('onboarding', 25, 50) : invalid('< 10 posts read')
        when 'first_day_visited'
          return stats['days_visited'].to_i >= 1 ? ok('onboarding', 10, 25) : invalid('no days visited')
        when 'set_location'
          # v0.35.0 - location capture quest (feeds geo digests + local feed)
          loc = (user.user_profile&.location || '').to_s.strip
          return loc.length >= 3 ? ok('onboarding', 50, 50) : invalid('no location set')
        end

        # v0.36.0 - diamond hands: continuous on-chain M3M3 stake duration.
        # first_seen comes from the staker-sync continuity ledger; unstaking
        # (or dropping off the top list) resets it.
        if (m = quest_id.match(/\Adh_stake_(30|90|180)\z/))
          days = m[1].to_i
          info = ::DiscourseCoinEngine::Stake2Earn.staker_info_for_user(user)
          return invalid('not currently staking on-chain') unless info
          return invalid('no stake history yet') unless info[:first_seen]
          held = ((Time.now - info[:first_seen]) / 86_400).floor
          return invalid("staked #{held}d < #{days}d") if held < days
          return ok('diamond', days * 20, days * 100)
        end

        # 7. v0.20.0 Path A — Charity samm_* quests use client-only localStorage
        # flags (samm_visit, samm_cheer, samm_donate, samm_share, samm_dayone).
        # Server has no source of truth for these, so they are trophy-only on
        # the client and rejected here. Re-enable when server-side flag tracking
        # ships (proposed v0.21.0).
        if quest_id.start_with?('samm_')
          return invalid('charity flags client-only, trophy-only no XP/RENO grant')
        end

        # 8. Milestones (ms_*) — verified by claim count
        if quest_id.start_with?('ms_')
          return validate_milestone(user, quest_id)
        end

        invalid('unknown quest_id')
      end

      private

      def ok(category, xp, reno)
        {
          valid: true,
          xp:    [xp.to_i,   MAX_XP_PER_CLAIM   ].min,
          reno:  [reno.to_i, MAX_RENO_PER_CLAIM ].min,
          category: category
        }
      end

      def invalid(reason)
        { valid: false, xp: 0, reno: 0, reason: reason }
      end

      # Pull stats from UserStat (Discourse's per-user aggregates) and User
      def user_stats(user)
        ustat = user.user_stat
        {
          'post_count'        => user.post_count.to_i,
          'topic_count'       => user.topic_count.to_i,
          'likes_given'       => ustat&.likes_given.to_i,
          'likes_received'    => ustat&.likes_received.to_i,
          'days_visited'      => ustat&.days_visited.to_i,
          'posts_read_count'  => ustat&.posts_read_count.to_i,
          'topics_entered'    => ustat&.topics_entered.to_i,
          'time_read'         => ustat&.time_read.to_i,
        }
      end

      def wallet_set?(user)
        field_id = SiteSetting.coin_engine_solana_field_id.to_i
        return false if field_id <= 0
        val = (user.user_fields || {})[field_id.to_s].to_s.strip
        val.length > 20 && ::DiscourseCoinEngine.respond_to?(:valid_solana_address?) ?
          ::DiscourseCoinEngine.valid_solana_address?(val) :
          val.length > 20
      end

      def current_user_rank(user_id)
        # Canonical shared helper — same filter as the public leaderboard.
        ::DiscourseCoinEngine.rank_for(user_id)
      rescue StandardError
        nil
      end

      def validate_milestone(user, quest_id)
        # v0.20.0 Path A — only server-verifiable milestones grant XP/RENO.
        # ms_charity_hero (5 client localStorage flags) and ms_perfectionist
        # (catalog-relative "ALL quests") have no server source of truth, so
        # they are trophy-only on the client and rejected here.
        if quest_id == 'ms_charity_hero' || quest_id == 'ms_perfectionist'
          return invalid('client-only state, trophy-only no XP/RENO grant')
        end

        # ms_balanced / ms_balanced_500 — both likes_given AND likes_received >= N
        if (m = quest_id.match(/\Ams_balanced(?:_(\d+))?\z/))
          thr = m[1] ? m[1].to_i : 100
          ustat = user.user_stat
          given = ustat&.likes_given.to_i
          recv  = ustat&.likes_received.to_i
          return invalid("likes_given=#{given} or likes_received=#{recv} < #{thr}") if given < thr || recv < thr
          xp   = thr >= 500 ? 5_000  : 1_000
          reno = thr >= 500 ? 15_000 : 3_000
          return ok('milestone', xp, reno)
        end

        # Server-verifiable claim-count milestones
        thresholds = {
          'ms_completionist_50'  => [50,    5_000,  15_000],
          'ms_completionist_100' => [100,  10_000,  25_000],
          'ms_completionist_150' => [150,  15_000,  40_000],
          'ms_grand_slam'        => [200,  25_000,  50_000],
        }

        # Streak quests — server-verified via StreakCalculator (reads
        # gamification_scores dates, not client counter)
        if (m = quest_id.match(/\Astreak_(\d+)\z/))
          thr = m[1].to_i
          actual = begin
            ::DiscourseCoinEngine::StreakCalculator.new(user_id: user.id).current
          rescue StandardError
            0
          end
          return invalid("streak=#{actual} < #{thr}") if actual < thr
          xp   = (thr * 30).clamp(50, MAX_XP_PER_CLAIM)
          reno = (thr * 75).clamp(100, MAX_RENO_PER_CLAIM)
          return ok('streaks', xp, reno)
        end

        if thresholds.key?(quest_id)
          required, xp, reno = thresholds[quest_id]
          actual = ::DiscourseCoinEngine::QuestClaim.where(user_id: user.id).count
          return invalid("claims=#{actual} < #{required}") if actual < required
          return ok('milestone', xp, reno)
        end
        invalid('unknown milestone')
      end

      def tier_xp(threshold)
        # Same scaling as client widget tierQ default
        [Math.sqrt(threshold) * 50, MAX_XP_PER_CLAIM].min.to_i.clamp(10, MAX_XP_PER_CLAIM)
      end

      def tier_reno(threshold)
        # Roughly 5 RENO per unit, capped
        [threshold * 5, MAX_RENO_PER_CLAIM].min.to_i.clamp(25, MAX_RENO_PER_CLAIM)
      end
    end
  end
end
