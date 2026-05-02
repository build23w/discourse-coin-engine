# frozen_string_literal: true

# v0.10.0 — Random-reach bounty dispatcher.
#
# Lifecycle:
#   1. Bounty created with bounty_type='random_reach' (lib creates the row).
#   2. Caller invokes BountyDispatcher.dispatch_round!(bounty)
#      → picks K random qualifying online users
#      → INSERTs invitation rows
#      → DMs each invitee
#      → MessageBus pushes a "you're invited" event so any open FAB lights up
#      → schedules expire_round! to fire at bounty.window_minutes from now
#   3. When an invitee replies on the bounty topic (DiscourseEvent :post_created),
#      BountyDispatcher.attempt_claim!(bounty, user, post) fires:
#      → atomic INSERT into coin_engine_bounty_claims (ON CONFLICT DO NOTHING)
#      → if INSERTed AND claims_count < max_winners, credit the winner
#      → if claims_count reaches max_winners, mark bounty awarded
#   4. Sidekiq job DiscourseCoinEngine::Jobs::ExpireBountyRound fires after window:
#      → if any qualifying claim landed → close bounty
#      → else if invitation_round < max_rounds → dispatch_round! again with new K
#      → else refund the poster, mark bounty 'expired'
#
# Anti-abuse:
#   - Min trust level (configurable, default TL2)
#   - Online filter: last_seen_at within ONLINE_WINDOW (default 5 min)
#   - Excludes: poster, already-invited (prior rounds), suspended/silenced
#   - Per-user-per-day claim cap (configurable)

module DiscourseCoinEngine
  class BountyDispatcher
    ONLINE_WINDOW          = 5.minutes      # last_seen_at threshold
    MAX_ROUNDS             = 3              # how many times we retry if no one bites
    DEFAULT_MIN_TRUST_LEVEL = 2

    class << self
      # Picks K random qualifying online users (excluding the poster and prior invitees).
      def select_invitees(bounty, count)
        return [] unless bounty
        already_invited = ::DiscourseCoinEngine::BountyInvitation
                            .where(bounty_id: bounty.id).pluck(:user_id)
        excluded_ids = (already_invited + [bounty.poster_user_id]).uniq

        min_tl = (SiteSetting.coin_engine_bounty_min_tl rescue DEFAULT_MIN_TRUST_LEVEL).to_i
        cutoff = ONLINE_WINDOW.ago
        scope = ::User
                  .where('last_seen_at > ?', cutoff)
                  .where('trust_level >= ?', min_tl)
                  .where(active: true, suspended_till: nil, silenced_till: nil, staged: false)
                  .where('id > 0')
        scope = scope.where.not(id: excluded_ids) if excluded_ids.any?
        # ORDER BY RANDOM() is OK here — at forum scale (thousands of online users
        # at most) the cost is negligible. Use TABLESAMPLE if it grows.
        scope.order(Arel.sql('RANDOM()')).limit(count.to_i).to_a
      end

      def dispatch_round!(bounty)
        return false unless bounty
        return false unless bounty.bounty_type == 'random_reach'
        return false unless bounty.status == 'open'

        round = bounty.invitation_round.to_i + 1
        return false if round > MAX_ROUNDS

        users = select_invitees(bounty, bounty.invite_count)
        if users.empty?
          Rails.logger.warn("[coin_engine] bounty #{bounty.id} round #{round}: no online users matched criteria")
          return false
        end

        now = Time.now
        next_at = now + bounty.window_minutes.minutes
        ActiveRecord::Base.transaction do
          users.each do |u|
            ::DiscourseCoinEngine::BountyInvitation.create!(
              bounty_id: bounty.id, user_id: u.id, round: round, invited_at: now
            )
          end
          bounty.update!(invitation_round: round, next_round_at: next_at)
        end

        users.each { |u| notify_invitee(bounty, u) }
        schedule_expiry!(bounty)
        Rails.logger.info("[coin_engine] bounty #{bounty.id} round #{round}: invited #{users.size} users")
        true
      end

      # Atomic claim attempt. Returns hash: {ok:, granted:, reason?}.
      # Caller is the post_created hook OR an explicit claim button.
      def attempt_claim!(bounty, user, post = nil)
        return { ok: false, reason: 'no bounty' }              unless bounty
        return { ok: false, reason: 'no user' }                unless user
        return { ok: false, reason: 'not_random_reach' }       unless bounty.bounty_type == 'random_reach'
        return { ok: false, reason: 'bounty_not_open' }        unless bounty.status == 'open'
        return { ok: false, reason: 'self_claim' }             if user.id == bounty.poster_user_id

        invite = ::DiscourseCoinEngine::BountyInvitation.find_by(bounty_id: bounty.id, user_id: user.id)
        return { ok: false, reason: 'not_invited' } unless invite

        # Per-user-per-day cap (anti-abuse)
        cap = (SiteSetting.coin_engine_bounty_max_wins_per_day rescue 5).to_i
        recent_wins = ::DiscourseCoinEngine::BountyClaim.where(user_id: user.id).where('claimed_at > ?', 24.hours.ago).count
        return { ok: false, reason: 'daily_cap_reached' } if recent_wins >= cap

        # Quality gate: minimum reply length
        min_len = (SiteSetting.coin_engine_bounty_min_reply_chars rescue 80).to_i
        if post && post.respond_to?(:raw) && post.raw.to_s.strip.length < min_len
          return { ok: false, reason: 'reply_too_short' }
        end

        # Atomic claim with capacity check.
        # SQL: insert claim row UNLESS already-claimed; bump counter atomically;
        # if counter would exceed max_winners, rollback.
        share = (bounty.amount.to_i / [bounty.max_winners.to_i, 1].max)
        granted = false
        ActiveRecord::Base.transaction do
          # Atomic insert claim — uniqueness on (bounty_id, user_id) prevents double-claim.
          quoted_now = ActiveRecord::Base.connection.quote(Time.now)
          ins = ActiveRecord::Base.connection.execute(<<~SQL)
            INSERT INTO coin_engine_bounty_claims
              (bounty_id, user_id, post_id, awarded_amount, claimed_at, created_at, updated_at)
            VALUES
              (#{bounty.id.to_i}, #{user.id.to_i}, #{post && post.id.to_i || 'NULL'},
               #{share.to_i}, #{quoted_now}, #{quoted_now}, #{quoted_now})
            ON CONFLICT (bounty_id, user_id) DO NOTHING
            RETURNING id
          SQL
          rows_inserted = ins.to_a
          if rows_inserted.empty?
            return { ok: false, reason: 'already_claimed' }
          end

          # Atomic capacity bump. If this UPDATE matches no rows, the bounty
          # already filled to max_winners by a concurrent claim — roll back.
          upd = ActiveRecord::Base.connection.execute(<<~SQL)
            UPDATE coin_engine_bounties
            SET claims_count = claims_count + 1
            WHERE id = #{bounty.id.to_i}
              AND claims_count < max_winners
              AND status = 'open'
            RETURNING claims_count, max_winners
          SQL
          row = upd.to_a.first
          unless row
            # Lost the race: undo the claim insert
            ActiveRecord::Base.connection.execute("DELETE FROM coin_engine_bounty_claims WHERE bounty_id = #{bounty.id.to_i} AND user_id = #{user.id.to_i}")
            return { ok: false, reason: 'bounty_full' }
          end

          # Credit the winner
          ::DiscourseCoinEngine.credit_score(user.id, Date.today, share)
          ::DiscourseCoinEngine.refresh_user_score(user.id)

          # Mark invitation responded + won
          invite.update!(responded_at: Time.now, won: true)

          # If all winner slots are filled, close the bounty
          if row['claims_count'].to_i >= row['max_winners'].to_i
            bounty.update!(status: 'awarded', winner_user_id: user.id, winning_post_id: post&.id, awarded_at: Time.now)
          end

          granted = true
        end

        # Notify outside the transaction (no rollback risk on PM failure)
        if granted
          notify_winner(bounty, user, share, post)
          notify_other_invitees_of_close(bounty, winner: user) if bounty.reload.status == 'awarded'
        end
        { ok: true, granted: true, amount: share, bounty_id: bounty.id }
      rescue StandardError => e
        Rails.logger.error("[coin_engine] BountyDispatcher.attempt_claim! failed: #{e.class}: #{e.message}")
        { ok: false, reason: "exception: #{e.message}" }
      end

      def expire_round!(bounty)
        return unless bounty
        bounty.reload
        return unless bounty.bounty_type == 'random_reach' && bounty.status == 'open'

        # Did anyone claim during this round?
        if bounty.claims_count.to_i >= bounty.max_winners.to_i
          # Already awarded — nothing to do
          return
        end

        # No-show round: try again with fresh K, OR refund + close
        if bounty.invitation_round.to_i < MAX_ROUNDS
          dispatch_round!(bounty)
        else
          refund_and_close!(bounty)
        end
      end

      def refund_and_close!(bounty)
        amt = bounty.amount.to_i
        return unless amt > 0
        ActiveRecord::Base.transaction do
          ::DiscourseCoinEngine.credit_score(bounty.poster_user_id, Date.today, amt)
          ::DiscourseCoinEngine.refresh_user_score(bounty.poster_user_id)
          bounty.update!(status: 'expired')
        end
        # Notify poster
        begin
          ::DiscourseCoinEngine::Notifier.credit!(
            recipient: ::User.find(bounty.poster_user_id),
            amount: amt,
            reason: 'bounty_refund',
            sender: nil,
            note: "Your bounty expired with no winners — refund issued.",
            ref: { type: 'bounty', id: bounty.id }
          )
        rescue StandardError => e
          Rails.logger.warn("[coin_engine] bounty refund notify failed: #{e.message}")
        end
      end

      private

      def notify_invitee(bounty, user)
        # PM
        begin
          coin = SiteSetting.coin_engine_coin_name
          poster = ::User.find_by(id: bounty.poster_user_id)
          topic = ::Topic.find_by(id: bounty.topic_id)
          topic_url = topic ? "/t/#{topic.slug}/#{topic.id}" : "/"
          window = bounty.window_minutes.to_i
          share = (bounty.amount.to_i / [bounty.max_winners.to_i, 1].max)
          title = "🎯 You've been picked for a #{coin} bounty"
          body  = +"@#{poster&.username || 'someone'} is offering a **#{coin} bounty** and you've been picked.\n\n"
          body  << "**#{share} #{coin}** for the first qualifying reply on:\n"
          body  << "[#{topic&.title || 'View topic'}](#{topic_url})\n\n"
          body  << "⏱ You have **#{window} minutes** — #{bounty.invite_count - 1} other forum members were also invited.\n\n"
          body  << (bounty.note.to_s.strip.length > 0 ? "**The ask:** #{bounty.note}\n\n" : '')
          body  << "Move fast. First substantive reply wins.\n"

          ::PostCreator.create!(
            ::Discourse.system_user,
            title: title,
            raw: body,
            archetype: ::Archetype.private_message,
            target_usernames: user.username,
            skip_validations: true,
          )
        rescue StandardError => e
          Rails.logger.warn("[coin_engine] bounty PM failed for user #{user.id}: #{e.message}")
        end

        # MessageBus push so open tabs light up
        begin
          MessageBus.publish("/coin-engine/bounty-invite/#{user.id}", {
            bounty_id: bounty.id,
            topic_id: bounty.topic_id,
            amount: bounty.amount,
            share: (bounty.amount.to_i / [bounty.max_winners.to_i, 1].max),
            window_minutes: bounty.window_minutes,
            expires_at: (Time.now + bounty.window_minutes.minutes).to_i,
            note: bounty.note.to_s,
          }, user_ids: [user.id])
        rescue StandardError => e
          Rails.logger.warn("[coin_engine] bounty MessageBus failed: #{e.message}")
        end
      end

      def notify_winner(bounty, winner, amount, post)
        ::DiscourseCoinEngine::Notifier.credit!(
          recipient: winner,
          amount: amount,
          reason: 'bounty_award',
          sender: ::User.find_by(id: bounty.poster_user_id),
          note: "Random-reach bounty won! Topic: #{::Topic.find_by(id: bounty.topic_id)&.title}",
          ref: { type: 'bounty', id: bounty.id, post_id: post&.id }
        )
      rescue StandardError => e
        Rails.logger.warn("[coin_engine] notify_winner failed: #{e.message}")
      end

      def notify_other_invitees_of_close(bounty, winner:)
        # Best-effort: tell other invitees the bounty closed. Skip if too many.
        invitees = ::DiscourseCoinEngine::BountyInvitation
                     .where(bounty_id: bounty.id)
                     .where.not(user_id: winner.id)
                     .limit(20)
        invitees.each do |inv|
          begin
            MessageBus.publish("/coin-engine/bounty-invite/#{inv.user_id}", {
              bounty_id: bounty.id,
              closed: true,
              winner_username: winner.username,
            }, user_ids: [inv.user_id])
          rescue StandardError
            nil
          end
        end
      end

      def schedule_expiry!(bounty)
        ::Jobs.enqueue_in(
          bounty.window_minutes.minutes + 30.seconds,
          :expire_bounty_round,
          bounty_id: bounty.id
        )
      rescue StandardError => e
        Rails.logger.warn("[coin_engine] bounty expiry schedule failed: #{e.message}")
      end
    end
  end
end
