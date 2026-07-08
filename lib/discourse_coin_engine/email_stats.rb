# frozen_string_literal: true

# v0.35.0 - Per-day, per-campaign, per-city email funnel counters
# (sent / clicked / rewarded), PluginStore-backed. Answers "does the Toronto
# daily digest actually convert to visits?" without any analytics infra.
module ::DiscourseCoinEngine
  class EmailStats
    STORE = 'discourse-coin-engine'

    class << self
      def record_send!(campaign:, city: nil);   bump!('sent',     campaign: campaign, city: city); end
      def record_click!(campaign:, city: nil);  bump!('clicked',  campaign: campaign, city: city); end
      def record_reward!(campaign:, city: nil); bump!('rewarded', campaign: campaign, city: city); end

      # { "2026-07-08" => { "daily|toronto" => { "sent" => 12, "clicked" => 4, "rewarded" => 3 }, ... }, ... }
      def summary(days: 14)
        (0...days).each_with_object({}) do |i, out|
          d = Date.today - i
          h = ::PluginStore.get(STORE, "email_stats_#{d}")
          out[d.to_s] = h if h.present?
        end
      end

      private

      def bump!(kind, campaign:, city: nil, day: Date.today)
        ::DistributedMutex.synchronize("ce_email_stats_#{day}") do
          key = "email_stats_#{day}"
          h = ::PluginStore.get(STORE, key) || {}
          k = "#{campaign}|#{city.to_s.strip.downcase.presence || 'site'}"
          row = h[k] || {}
          row[kind] = row[kind].to_i + 1
          h[k] = row
          ::PluginStore.set(STORE, key, h)
        end
      rescue StandardError => e
        Rails.logger.warn("[coin-engine] email stats bump failed: #{e.message}")
      end
    end
  end
end
