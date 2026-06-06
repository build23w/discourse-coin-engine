# frozen_string_literal: true

module DiscourseCoinEngine
  class EmailGate
    NO_EMAIL_FIELD     = 'coin_engine_no_email'
    UNVERIFIED_FIELD   = 'coin_engine_email_unverified'
    PLACEHOLDER_DOMAIN = 'no-mail.invalid'

    def self.allowed?(user)
      return false unless user
      return false if user.suspended?
      return false if user.respond_to?(:silenced?) && user.silenced?
      return false unless user.active?

      email = user.email.to_s.downcase
      return false if email.empty?
      return false if email.end_with?("@#{PLACEHOLDER_DOMAIN}")

      # BUG FIX (2026-06-06): user.user_custom_fields is the AR association
      # (an ARRAY of records) — indexing it with a string key raised TypeError
      # for every user who HAS custom fields, and the fail-closed rescue then
      # silently blocked their email. user.custom_fields is the hash API.
      cf = user.custom_fields || {}
      return false if cf[NO_EMAIL_FIELD].to_s == '1'

      if cf[UNVERIFIED_FIELD].to_s == '1'
        if ::EmailToken.where(user_id: user.id, email: email, confirmed: true).exists?
          # Auto-clear: verification has completed via standard prefs flow.
          ::UserCustomField.where(user_id: user.id, name: UNVERIFIED_FIELD).delete_all
          user.custom_fields.delete(UNVERIFIED_FIELD) rescue nil
          return true
        end
        return false
      end

      true
    rescue StandardError => e
      Rails.logger.warn("[coin-engine] EmailGate.allowed? errored for user=#{user&.id}: #{e.class}: #{e.message}")
      # Fail-closed: if we can't tell, don't send.
      false
    end

    def self.suppress_user_emails!(user, reason:)
      return unless user&.id

      field = (reason == :no_email) ? NO_EMAIL_FIELD : UNVERIFIED_FIELD
      ::UserCustomField.where(user_id: user.id, name: field).delete_all
      ::UserCustomField.create!(user_id: user.id, name: field, value: '1')

      uo = user.user_option || user.build_user_option
      uo.email_digests          = false                    if uo.respond_to?(:email_digests=)
      uo.mailing_list_mode      = false                    if uo.respond_to?(:mailing_list_mode=)
      # 3 = "never" in the email_level_types enum (always / only_when_away / never)
      uo.email_level            = 3                        if uo.respond_to?(:email_level=)
      uo.email_messages_level   = 3                        if uo.respond_to?(:email_messages_level=)
      uo.save! if uo.changed?

      Rails.logger.info("[coin-engine] EmailGate.suppress! user=#{user.id} reason=#{reason}")
    rescue StandardError => e
      Rails.logger.warn("[coin-engine] EmailGate.suppress! failed user=#{user&.id}: #{e.class}: #{e.message}")
    end

    def self.placeholder_email_for(pubkey)
      "wallet-#{pubkey.to_s[0, 12].downcase}@#{PLACEHOLDER_DOMAIN}"
    end
  end
end
