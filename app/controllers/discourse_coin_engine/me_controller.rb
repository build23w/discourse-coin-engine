# frozen_string_literal: true

# v0.9.1 — On-demand fresh score endpoint.
#
# Both `coin_engine_score` and `gamification_score` are cached for ~5 min in
# their respective serializer attributes. When a user has just received a tip
# / quest reward / payment, the FAB might show the old number for up to 5 min.
#
# This endpoint reads gamification_scores DIRECTLY (no cache) and busts every
# known cache key in the process so the next page load is also up-to-date.
# Returns the unified total — ALL writes to gamification_scores from any source
# (discourse-gamification's auto-scoring, our credit_score, manual airdrops)
# contribute. There is no separate "$RENO total" vs "gamification total" — they
# are the same number, computed off the same SUM.

module DiscourseCoinEngine
  class MeController < ::ApplicationController
    requires_login
    skip_before_action :check_xhr, raise: false

    # GET /coin-engine/me/score.json
    # { score, rank, tier, sources: { ce_*: N, post: N, like: N, ... } }
    def score
      raise Discourse::InvalidAccess unless current_user
      uid = current_user.id

      # Bust caches FIRST so any other endpoint hit immediately after also gets fresh.
      ::DiscourseCoinEngine.refresh_user_score(uid) if ::DiscourseCoinEngine.respond_to?(:refresh_user_score)

      # Fresh total + per-source breakdown for transparency.
      total = ::DiscourseCoinEngine.coin_user_total(uid).to_i

      # Per-source breakdown — useful for "where does my $RENO come from?" UI later.
      # Empty if the gamification_scores table doesn't track source separately.
      sources = {}
      begin
        rows = ActiveRecord::Base.connection.exec_query(
          "SELECT date, SUM(score)::int AS total FROM gamification_scores " \
          "WHERE user_id = #{uid.to_i} GROUP BY date ORDER BY date DESC LIMIT 30"
        ).to_a
        sources[:by_date] = rows
      rescue StandardError
        sources[:by_date] = []
      end

      # Live rank
      rank = nil
      begin
        sql = <<~SQL
          WITH totals AS (
            SELECT user_id, SUM(score) AS total
            FROM gamification_scores WHERE user_id > 0 GROUP BY user_id
          )
          SELECT rank FROM (
            SELECT user_id, RANK() OVER (ORDER BY total DESC) AS rank FROM totals
          ) ranked WHERE user_id = #{uid.to_i}
        SQL
        rank = ActiveRecord::Base.connection.exec_query(sql).rows.first&.first&.to_i
      rescue StandardError
        nil
      end

      # Tier resolution
      tier = nil
      begin
        if defined?(::DiscourseCoinEngine::TierResolver)
          tier = ::DiscourseCoinEngine::TierResolver.new(total).call
        end
      rescue StandardError
        nil
      end

      render json: {
        user_id: uid,
        username: current_user.username,
        score:   total,         # canonical: same number as gamification_score AND coin_engine_score
        rank:    rank,
        tier:    tier,
        coin:    SiteSetting.coin_engine_coin_name,
        as_of:   Time.now.to_i,
        sources: sources,
      }
    end
  end
end
