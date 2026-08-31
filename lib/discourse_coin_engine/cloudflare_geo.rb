# frozen_string_literal: true

# v0.37.0 - Edge geolocation from Cloudflare.
#
# WHY THIS EXISTS
# Two problems, one fix.
#
# 1. This origin does not see real client IPs. Staff-action logs record
#    10.1.0.0 (an internal proxy hop), so anything downstream of the IP - the
#    MaxMind lookup included - geolocates the proxy, not the visitor. Fixing
#    the real-IP chain (trusting CF-Connecting-IP from Cloudflare ranges) is
#    worth doing for rate limiting and abuse tooling, but geo does not need to
#    wait for it: Cloudflare resolves location AT THE EDGE and hands it to us
#    in request headers, which is unaffected by the broken IP chain.
#
# 2. GeoDigest only reads `user_profile.location`, a field the user types by
#    hand. Almost nobody fills it in, so geo-scoped digests fall back to the
#    site-wide list for nearly everyone.
#
# WHAT THIS DOES NOT DO
# It never overwrites a location the user stated themselves - a typed profile
# location always wins. The inferred value is kept in a separate custom field
# used only for digest targeting, so it is a fallback, not a claim about them.
#
# REQUIRES: Cloudflare dashboard -> Rules -> Transform Rules -> Managed
# Transforms -> "Add visitor location headers" = ON. Without it only
# CF-IPCountry arrives and city/region targeting stays unavailable.
module ::DiscourseCoinEngine
  class CloudflareGeo
    CITY_FIELD    = 'coin_engine_cf_city'
    REGION_FIELD  = 'coin_engine_cf_region'
    COUNTRY_FIELD = 'coin_engine_cf_country'
    SEEN_FIELD    = 'coin_engine_cf_geo_at'

    # Cloudflare sends these only when the managed transform is enabled.
    HEADERS = {
      city:    %w[HTTP_CF_IPCITY CF-IPCity],
      region:  %w[HTTP_CF_REGION CF-Region],
      country: %w[HTTP_CF_IPCOUNTRY CF-IPCountry]
    }.freeze

    MAX_LEN = 80

    class << self
      def enabled?
        SiteSetting.coin_engine_cf_geo_enabled
      rescue StandardError
        false
      end

      # Cheap enough for a before_action: one cache read on the hot path.
      def capture(user, request)
        return unless user && request && enabled?

        key = "ce_cfgeo_#{user.id}"
        return if Discourse.cache.read(key)

        parts = read_headers(request)
        return if parts[:city].blank? && parts[:country].blank?

        Discourse.cache.write(key, 1, expires_in: 12.hours)
        persist(user, parts)
      rescue StandardError => e
        Rails.logger.warn("[coin-engine] CloudflareGeo.capture failed user=#{user&.id}: #{e.class}: #{e.message}")
        nil
      end

      # "Toronto, Ontario, CA" - shaped like a typed profile location so
      # GeoDigest's existing comma tokenizer handles it unchanged.
      def location_for(user)
        return '' unless user && enabled?
        cf = user.custom_fields || {}
        [cf[CITY_FIELD], cf[REGION_FIELD], cf[COUNTRY_FIELD]]
          .map { |v| v.to_s.strip }.reject(&:empty?).join(', ')
      rescue StandardError
        ''
      end

      def inferred?(user)
        location_for(user).present?
      end

      private

      def read_headers(request)
        HEADERS.transform_values do |names|
          raw = names.lazy.map { |n| request.headers[n] }.find(&:present?)
          clean(raw)
        end
      end

      # CF percent-encodes non-ASCII city names; also guard junk like "XX"/"T1".
      def clean(value)
        v = value.to_s.strip
        return '' if v.empty?
        v = CGI.unescape(v) rescue v
        v = v.strip.delete("\r\n\t")[0, MAX_LEN].to_s
        return '' if v.casecmp('xx').zero? || v.casecmp('t1').zero?
        v
      end

      def persist(user, parts)
        changed = false
        {
          CITY_FIELD    => parts[:city],
          REGION_FIELD  => parts[:region],
          COUNTRY_FIELD => parts[:country]
        }.each do |field, value|
          next if value.blank?
          next if user.custom_fields[field].to_s == value
          # user_custom_fields has no unique index - delete then insert.
          ::UserCustomField.where(user_id: user.id, name: field).delete_all
          ::UserCustomField.create!(user_id: user.id, name: field, value: value)
          changed = true
        end
        return unless changed

        ::UserCustomField.where(user_id: user.id, name: SEEN_FIELD).delete_all
        ::UserCustomField.create!(user_id: user.id, name: SEEN_FIELD, value: Time.now.utc.iso8601)
        user.reload_custom_fields rescue user.custom_fields.reload rescue nil
        Rails.logger.info("[coin-engine] CloudflareGeo user=#{user.id} -> #{parts[:city]}, #{parts[:region]}, #{parts[:country]}")
      end
    end
  end
end
