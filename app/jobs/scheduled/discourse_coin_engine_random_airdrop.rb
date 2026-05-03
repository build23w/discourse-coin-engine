# frozen_string_literal: true

# Daily job — picks N random active users and drops $RENO. Public ledger entry posted.
# Disabled until coin_engine_random_airdrop_enabled flips on.
module ::Jobs
  class DiscourseCoinEngineRandomAirdrop < ::Jobs::Scheduled
    every 1.day

    def execute(args)
      return unless SiteSetting.coin_engine_enabled
      return unless SiteSetting.coin_engine_random_airdrop_enabled rescue false
      n = (SiteSetting.coin_engine_random_airdrop_count rescue 5).to_i.clamp(0, 50)
      amount = (SiteSetting.coin_engine_random_airdrop_amount rescue 25).to_i
      return if n <= 0 || amount <= 0

      # Pick from users active in the last 7 days
      candidate_ids = ::User.where(staged: false, suspended_till: nil)
                            .where('id > 0')
                            .where('last_seen_at > ?', 7.days.ago)
                            .pluck(:id).sample(n)
      today = Date.today
      candidate_ids.each do |uid|
        next if ::DiscourseCoinEngine::RandomAirdrop.find_by(user_id: uid, airdrop_date: today)
        ActiveRecord::Base.transaction do
          # v0.12.1 - credit_score helper so leaderboard ledger gets the airdrop
          ::DiscourseCoinEngine.credit_score(uid, today, amount)
          ::DiscourseCoinEngine::RandomAirdrop.create!(
            user_id: uid, amount: amount, airdrop_date: today, reason: 'random_kindness'
          )
          ::DiscourseCoinEngine.refresh_user_score(uid)
        end
      end
    rescue StandardError => e
      Rails.logger.warn("[coin_engine] random airdrop job: #{e.class} #{e.message}")
    end
  end
end
