# frozen_string_literal: true

# v0.24.0 — Recompute each squad's member_count + total_score from its members'
# lifetime gamification scores. total_score drives the squad leaderboard shown
# in the $RENO Hub "Squads" tab. Cheap: one bulk SUM query per squad.
module ::Jobs
  class DiscourseCoinEngineRefreshSquadScores < ::Jobs::Scheduled
    every 30.minutes

    def execute(_args = nil)
      return unless SiteSetting.coin_engine_enabled
      return unless defined?(::DiscourseCoinEngine::Squad)

      ::DiscourseCoinEngine::Squad.find_each do |squad|
        member_ids = ::DiscourseCoinEngine::SquadMembership.where(squad_id: squad.id).pluck(:user_id)
        totals = ::DiscourseCoinEngine.coin_user_total_bulk(member_ids)
        total_score = totals.values.map(&:to_i).sum
        squad.update_columns(
          member_count: member_ids.length,
          total_score:  total_score,
          updated_at:   Time.now,
        )
      end
    rescue StandardError => e
      Rails.logger.warn("[coin_engine] refresh_squad_scores: #{e.class} #{e.message}")
    end
  end
end
