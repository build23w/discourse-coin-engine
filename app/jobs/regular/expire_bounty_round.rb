# frozen_string_literal: true

# v0.10.0 — Fires bounty.window_minutes after a random_reach round opens.
# If no qualifying claim landed and we haven't hit MAX_ROUNDS, dispatches a
# new round of K invitees. Otherwise refunds the poster.

module ::Jobs
  class ExpireBountyRound < ::Jobs::Base
    def execute(args)
      bounty_id = args[:bounty_id]
      return unless bounty_id
      bounty = ::DiscourseCoinEngine::Bounty.find_by(id: bounty_id)
      return unless bounty
      ::DiscourseCoinEngine::BountyDispatcher.expire_round!(bounty)
    rescue StandardError => e
      Rails.logger.warn("[coin_engine] ExpireBountyRound #{bounty_id}: #{e.class}: #{e.message}")
    end
  end
end
