# frozen_string_literal: true

# v0.35.0 - HMAC-signed email link tokens. Lets an engagement-email click
# identify + credit the recipient WITHOUT requiring a logged-in session,
# while making forgery/replay-for-others impossible (the token binds
# user_id, send day, campaign, city, optional action, and destination).
#
#   tok = EmailToken.generate(user_id: 42, dest: '/t/slug/123', campaign: 'daily', city: 'Toronto')
#   EmailToken.verify(tok) #=> { user_id: 42, day: '2026-07-08', campaign: 'daily',
#                                city: 'Toronto', action: nil, dest: '/t/slug/123' }
module ::DiscourseCoinEngine
  class EmailToken
    STORE = 'discourse-coin-engine'
    SECRET_KEY = 'email_token_secret'

    class << self
      def secret
        @secret ||= begin
          s = ::PluginStore.get(STORE, SECRET_KEY)
          if s.blank?
            s = SecureRandom.hex(32)
            ::PluginStore.set(STORE, SECRET_KEY, s)
          end
          s
        end
      end

      def generate(user_id:, dest:, campaign:, city: nil, action: nil, day: Date.today)
        data = [user_id, day.to_s, campaign.to_s, city.to_s, action.to_s, dest.to_s].join('|')
        b64 = Base64.urlsafe_encode64(data, padding: false)
        "#{b64}.#{sign(b64)}"
      end

      def verify(token)
        b64, sig = token.to_s.split('.', 2)
        return nil if b64.blank? || sig.blank?
        return nil unless ActiveSupport::SecurityUtils.secure_compare(sig, sign(b64))
        user_id, day, campaign, city, action, dest = Base64.urlsafe_decode64(b64).split('|', 6)
        {
          user_id: user_id.to_i,
          day: day,
          campaign: campaign.presence || 'unknown',
          city: city.presence,
          action: action.presence,
          dest: dest.to_s,
        }
      rescue StandardError
        nil
      end

      private

      def sign(b64)
        OpenSSL::HMAC.hexdigest('SHA256', secret, b64)[0, 24]
      end
    end
  end
end
