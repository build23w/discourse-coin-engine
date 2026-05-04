# frozen_string_literal: true

# v0.14.0 - Notifier subscription stub.
#
# The Notifier is a coin-pump alert tool. Backend isn't built yet, but the
# FAB hub has a "Connect Notifier" button that POSTs here to register
# interest. We log to Rails.logger and (best-effort) write to the user's
# custom_fields so we have a list of interested users when we build the
# real notifier service.
#
# When the real service ships, this endpoint can grow into a full
# subscription manager (channel preferences, thresholds, quiet hours).

module DiscourseCoinEngine
  class NotifierController < ::ApplicationController
    requires_login
    before_action :ensure_logged_in
    skip_before_action :check_xhr, raise: false

    # POST /coin-engine/notifier/subscribe.json
    def subscribe
      RateLimiter.new(current_user, 'coin_engine_notifier_subscribe', 5, 1.hour).performed!

      source = params[:source].to_s.strip[0, 32]
      now    = Time.zone.now

      Rails.logger.info("[coin_engine.notifier] interest user=#{current_user.id} source=#{source.inspect} email=#{current_user.email}")

      # Best-effort persist on user.custom_fields so we can query later
      # without a dedicated table.
      begin
        current_user.custom_fields['coin_engine_notifier_interested_at'] = now.iso8601
        current_user.custom_fields['coin_engine_notifier_source']        = source if source.present?
        current_user.save_custom_fields
      rescue StandardError => e
        Rails.logger.warn("[coin_engine.notifier] custom_fields save failed: #{e.message[0,160]}")
      end

      render json: {
        ok: true,
        message: 'Interest registered. We will email you when the Notifier launches.',
        interested_at: now.iso8601,
      }
    rescue RateLimiter::LimitExceeded => e
      render json: { errors: ["Slow down. Try again in #{e.available_in}s."] }, status: 429
    end
  end
end
