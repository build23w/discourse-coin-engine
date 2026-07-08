# frozen_string_literal: true

module Jobs
  # v0.36.0 - Stake2Earn staker sync. Refreshes the on-chain M3M3 top-staker
  # set, maintains the first-seen continuity ledger (diamond-hands quests),
  # and mirrors verified stakes onto matched forum accounts via custom fields
  # so boost/quest/status paths never touch RPC at request time.
  class DiscourseCoinEngineStakerSync < ::Jobs::Scheduled
    every 30.minutes

    def execute(args)
      return unless ::DiscourseCoinEngine::Stake2Earn.enabled?

      set = ::DiscourseCoinEngine::Stake2Earn.stakers(force: true)
      return if set.empty? # RPC hiccup: keep last known fields rather than wiping

      ::DiscourseCoinEngine::Stake2Earn.update_first_seen!(set)
      matched = ::DiscourseCoinEngine::Stake2Earn.forum_stakers(set)

      stake_f  = ::DiscourseCoinEngine::Stake2Earn::STAKE_FIELD
      wallet_f = ::DiscourseCoinEngine::Stake2Earn::WALLET_FIELD

      # Clear users no longer staking (unstaked or dropped from top list)
      stale_ids = ::UserCustomField.where(name: stake_f).pluck(:user_id) - matched.keys
      if stale_ids.any?
        ::UserCustomField.where(name: [stake_f, wallet_f], user_id: stale_ids).delete_all
      end

      matched.each do |user_id, info|
        # user_custom_fields has NO unique index - delete-then-insert.
        ::UserCustomField.where(user_id: user_id, name: [stake_f, wallet_f]).delete_all
        ::UserCustomField.create!(user_id: user_id, name: stake_f,  value: info[:stake_raw].to_s)
        ::UserCustomField.create!(user_id: user_id, name: wallet_f, value: info[:wallet].to_s)
      rescue StandardError => e
        Rails.logger.warn "[coin-engine] staker sync field write failed for #{user_id}: #{e.message}"
      end

      Rails.logger.info "[coin-engine] staker sync: #{set.size} on-chain stakers, #{matched.size} matched to forum accounts"
    end
  end
end
