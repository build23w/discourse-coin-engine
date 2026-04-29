# frozen_string_literal: true

module DiscourseCoinEngine
  # Single source of truth for "did this user already get a coin-engine engagement
  # email today". Backed by a user_custom_field that stores YYYY-MM-DD of the last
  # engagement-email send date. Hard rule: max 1 engagement email per user per day,
  # across ALL email types (digest, recap, top-picks, dormant-reengage, etc).
  #
  # Receipt-style emails (manual_payment_receipt, airdrop_notification, tier_up)
  # are NOT throttled here -- those are transactional, not engagement.
  class EmailThrottle
    FIELD_KEY = 'coin_engine_last_email_day'

    def self.may_send?(user_id)
      return false unless user_id && user_id > 0
      cf = ::UserCustomField.find_by(user_id: user_id, name: FIELD_KEY)
      cf.nil? || cf.value != Date.today.to_s
    end

    def self.mark_sent!(user_id)
      return unless user_id && user_id > 0
      cf = ::UserCustomField.find_or_initialize_by(user_id: user_id, name: FIELD_KEY)
      cf.value = Date.today.to_s
      cf.save!
    rescue StandardError
      # Don't let throttle bookkeeping break the actual send
    end
  end
end
