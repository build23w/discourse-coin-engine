# frozen_string_literal: true

# v0.9.0 — Quest reward claims.
# POST /coin-engine/quests/claim_batch.json { quest_ids: [...] }
# Client posts up to N quest_ids it believes are now completed; server validates
# each against the actual user record (not trusted from client beyond the id).
# Successful validations:
#   1. INSERT into coin_engine_quest_claims with ON CONFLICT (user_id, quest_id) DO NOTHING
#   2. If a row was inserted, credit gamification_scores via credit_score helper
#   3. Notify the user via the same MessageBus push the tip system uses
#
# Returns the per-quest result so the client can fire toasts only for grants
# that actually landed (and not for already-claimed or invalid ones).

module DiscourseCoinEngine
  class QuestsController < ::ApplicationController
    requires_login
    BATCH_LIMIT = 30

    # POST /coin-engine/quests/claim_batch.json
    def claim_batch
      RateLimiter.new(current_user, 'ce_quest_claim_batch', 60, 1.hour).performed!
      raise Discourse::InvalidAccess unless current_user
      ids = Array(params[:quest_ids]).map(&:to_s).reject(&:empty?).first(BATCH_LIMIT)
      return render(json: { results: [] }) if ids.empty?

      # Per-day cap to limit abuse even if validator misfires.
      max_per_day = (SiteSetting.coin_engine_quest_max_reno_per_day rescue 50_000).to_i
      already_today = ::DiscourseCoinEngine::QuestClaim
                        .where(user_id: current_user.id)
                        .where('created_at > ?', 24.hours.ago)
                        .sum(:reno_granted).to_i

      results = []
      ids.each do |qid|
        check = ::DiscourseCoinEngine::QuestValidator.validate(current_user, qid)
        unless check[:valid]
          results << { quest_id: qid, granted: false, reason: check[:reason] || 'invalid' }
          next
        end

        # Daily cap — if granting this would exceed it, skip the reward (still record claim).
        reno = check[:reno].to_i
        if already_today + reno > max_per_day
          reno = [max_per_day - already_today, 0].max
        end

        granted_now = false
        ActiveRecord::Base.transaction do
          # ON CONFLICT DO NOTHING idempotency. Returns 0 if duplicate.
          sql = <<~SQL
            INSERT INTO coin_engine_quest_claims
              (user_id, quest_id, xp_granted, reno_granted, category, created_at, updated_at)
            VALUES (#{current_user.id.to_i},
                    #{ActiveRecord::Base.connection.quote(qid)},
                    #{check[:xp].to_i},
                    #{reno.to_i},
                    #{ActiveRecord::Base.connection.quote(check[:category].to_s)},
                    NOW(), NOW())
            ON CONFLICT (user_id, quest_id) DO NOTHING
            RETURNING id
          SQL
          ins = ActiveRecord::Base.connection.execute(sql)
          if ins.respond_to?(:cmd_tuples) ? ins.cmd_tuples.to_i > 0 : !ins.to_a.empty?
            granted_now = true
            already_today += reno
            ::DiscourseCoinEngine.credit_score(current_user.id, Date.today, reno) if reno > 0
            ::DiscourseCoinEngine.refresh_user_score(current_user.id)
          end
        end

        if granted_now
          results << {
            quest_id:    qid,
            granted:     true,
            granted_xp:  check[:xp].to_i,
            granted_reno: reno,
            category:    check[:category],
          }
          # Push real-time toast to the user (their open browser tabs)
          if reno > 0
            begin
              MessageBus.publish("/coin-engine/credits/#{current_user.id}", {
                amount: reno,
                reason: 'quest_reward',
                label:  'Quest reward',
                coin:   SiteSetting.coin_engine_coin_name,
                new_total: ::DiscourseCoinEngine.coin_user_total(current_user.id),
                sender: nil,
                note:   "Quest: #{qid}",
                ref:    { type: 'quest', id: qid },
                ts:     Time.now.to_i,
              }, user_ids: [current_user.id])
            rescue StandardError => e
              Rails.logger.warn("[coin_engine] quest reward MessageBus failed: #{e.class}: #{e.message}")
            end
          end
        else
          results << { quest_id: qid, granted: false, reason: 'already_claimed' }
        end
      end

      render json: {
        coin: SiteSetting.coin_engine_coin_name,
        daily_remaining: [max_per_day - already_today, 0].max,
        results: results,
      }
    end

    # GET /coin-engine/quests/claims.json — what has the current user claimed?
    # Used by the widget to skip already-claimed quests and avoid re-POSTing.
    def list_claims
      raise Discourse::InvalidAccess unless current_user
      claims = ::DiscourseCoinEngine::QuestClaim.where(user_id: current_user.id).pluck(:quest_id)
      render json: { quest_ids: claims }
    end
  end
end
