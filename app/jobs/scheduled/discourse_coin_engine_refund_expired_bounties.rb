# frozen_string_literal: true

# v0.33.0 CE-017 — Hourly sweep that refunds expired-but-still-open bounties.
#
# Manual bounties had NO expiry path at all: ExpireBountyRound only handles
# random_reach rounds, so a manual bounty whose poster never awarded it kept
# the escrowed coins locked forever (live evidence: bounties 2-5, 220 coins,
# weeks past expires_at). This sweep catches those, plus any random_reach
# bounty whose Sidekiq expiry job was lost to a restart.
#
# refund_and_close! is race-safe (atomic open->expired flip) and refunds only
# the unpaid remainder, so sweeping a partially-paid random_reach bounty is
# safe too.

module Jobs
  class DiscourseCoinEngineRefundExpiredBounties < ::Jobs::Scheduled
    every 1.hour

    def execute(args)
      return unless SiteSetting.coin_engine_enabled rescue true

      stale = ::DiscourseCoinEngine::Bounty
                .where(status: 'open')
                .where('expires_at IS NOT NULL AND expires_at < ?', Time.now)
                .order(:expires_at)
                .limit(200)
                .to_a

      stale.each do |bounty|
        begin
          ::DiscourseCoinEngine::BountyDispatcher.refund_and_close!(bounty)
          Rails.logger.info("[coin_engine] refund_expired_bounties: closed bounty #{bounty.id}")
        rescue StandardError => e
          Rails.logger.warn("[coin_engine] refund_expired_bounties #{bounty.id}: #{e.class}: #{e.message}")
        end
      end
    end
  end
end
