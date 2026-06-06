# frozen_string_literal: true

# v0.32.0 — Ranking Pins. Dynamic, embeddable award pins companies place on
# their own websites (every embed = a live badge + a backlink to their forum
# profile = recurring referral traffic + SEO).
#
#   GET  /coin-engine/pin/:username.svg?style=fivestar|aplus|top3|pro|member
#   GET  /coin-engine/pin/:username/embed.json   -> available styles + snippets
#   POST /admin/coin-engine/pins/:user_id.json   -> { awards: "top3,aplus" } (admin)
#
# Rules: styles must be awarded (user_custom_field coin_engine_pin_awards) —
# unawarded requests gracefully fall back to the neutral "member" pin so an
# embed never 404s. Verified Pros (governance) automatically get the gold
# edition of every pin. SVGs are cached 30 min.
module DiscourseCoinEngine
  class PinController < ::ApplicationController
    requires_plugin 'discourse-coin-engine'
    skip_before_action :check_xhr, raise: false
    skip_before_action :redirect_to_login_if_required, raise: false

    AWARD_FIELD = 'coin_engine_pin_awards'
    STYLES = %w[fivestar aplus top3 pro member].freeze

    def svg
      user = ::User.find_by(username_lower: params[:username].to_s.downcase)
      raise ::Discourse::NotFound unless user
      style = STYLES.include?(params[:style].to_s) ? params[:style].to_s : 'member'
      verified = verified_pro?(user.id)
      style = resolve_style(user, style, verified)
      key = "ce_pin_#{user.id}_#{style}_#{verified ? 1 : 0}"
      body = Discourse.cache.fetch(key, expires_in: 30.minutes) do
        build_svg(user, style, verified)
      end
      response.headers['Cache-Control'] = 'public, max-age=1800'
      send_data body, type: 'image/svg+xml', disposition: 'inline'
    end

    def embed
      user = ::User.find_by(username_lower: params[:username].to_s.downcase)
      raise ::Discourse::NotFound unless user
      verified = verified_pro?(user.id)
      styles = (awards_for(user) + ['member'] + (verified ? ['pro'] : [])).uniq & STYLES
      base = Discourse.base_url
      render json: {
        username: user.username, verified_pro: verified, styles: styles,
        snippets: styles.map { |st|
          { style: st,
            html: %(<a href="#{base}/u/#{user.username}" rel="noopener"><img src="#{base}/coin-engine/pin/#{user.username}.svg?style=#{st}" alt="#{label_for(st)} — home.renovation.reviews" width="300" height="100" loading="lazy"></a>) }
        }
      }
    end

    def grant
      raise ::Discourse::InvalidAccess unless current_user&.admin?
      user = ::User.find_by(id: params[:user_id].to_i)
      raise ::Discourse::NotFound unless user
      awards = params[:awards].to_s.split(',').map(&:strip).select { |a| STYLES.include?(a) }
      # user_custom_fields has no unique index: delete-then-insert, never upsert.
      ::UserCustomField.where(user_id: user.id, name: AWARD_FIELD).delete_all
      ::UserCustomField.create!(user_id: user.id, name: AWARD_FIELD, value: awards.join(',')) if awards.any?
      STYLES.each { |st| [true, false].each { |v| Discourse.cache.delete("ce_pin_#{user.id}_#{st}_#{v ? 1 : 0}") } }
      render json: { ok: true, user_id: user.id, awards: awards }
    end

    private

    def awards_for(user)
      ::UserCustomField.where(user_id: user.id, name: AWARD_FIELD).pluck(:value).join(',').split(',').map(&:strip)
    end

    def verified_pro?(user_id)
      defined?(VerifiedPro) && VerifiedPro.where(user_id: user_id, verification_status: 'verified').exists?
    rescue StandardError
      false
    end

    def resolve_style(user, style, verified)
      return 'pro' if style == 'pro' && verified
      return style if style == 'member' || awards_for(user).include?(style)
      verified ? 'pro' : 'member'
    end

    def label_for(style)
      { 'fivestar' => '5-Star Rated Company', 'aplus' => 'A+ Rated Company',
        'top3' => 'Top 3 Ranked Company', 'pro' => 'Verified Pro',
        'member' => 'Reviewed Company' }[style]
    end

    def build_svg(user, style, verified)
      name = (user.name.presence || user.username).to_s[0, 28]
      year = Time.zone.now.year
      pal = {
        'fivestar' => %w[#0E3A5D #15B8A6],
        'aplus'    => %w[#14532D #22C55E],
        'top3'     => %w[#4C1D95 #F59E0B],
        'pro'      => %w[#1F2937 #B45309],
        'member'   => %w[#334155 #64748B],
      }[style]
      trim = verified ? '#FFD700' : 'rgba(255,255,255,.25)'
      icon =
        case style
        when 'fivestar' then (1..5).map { |i| %(<text x="#{96 + i * 26}" y="44" font-size="20" fill="#FFD700">★</text>) }.join
        when 'aplus'    then %(<text x="104" y="52" font-size="34" font-weight="800" fill="#FFFFFF">A+</text>)
        when 'top3'     then %(<text x="100" y="50" font-size="30" fill="#FFD700">\u{1F3C6}</text>)
        when 'pro'      then %(<text x="100" y="50" font-size="28" fill="#FFD700">✔</text>)
        else                 %(<text x="100" y="48" font-size="24" fill="#FFFFFF">⌂</text>)
        end
      vp_line = verified ? %(<text x="150" y="92" font-size="9" text-anchor="middle" fill="#FFD700" font-family="system-ui,Segoe UI,Arial">VERIFIED PRO • GOLD EDITION</text>) : ''
      <<~SVG
        <svg xmlns="http://www.w3.org/2000/svg" width="300" height="100" viewBox="0 0 300 100" role="img" aria-label="#{escape(label_for(style))}">
          <defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1">
            <stop offset="0" stop-color="#{pal[0]}"/><stop offset="1" stop-color="#{pal[1]}"/>
          </linearGradient></defs>
          <rect x="2" y="2" width="296" height="96" rx="14" fill="url(#g)" stroke="#{trim}" stroke-width="3"/>
          #{icon}
          <text x="150" y="26" font-size="13" font-weight="700" text-anchor="middle" fill="#FFFFFF" font-family="system-ui,Segoe UI,Arial">#{escape(label_for(style))} • #{year}</text>
          <text x="150" y="72" font-size="15" font-weight="800" text-anchor="middle" fill="#FFFFFF" font-family="system-ui,Segoe UI,Arial">#{escape(name)}</text>
          <text x="150" y="86" font-size="9" text-anchor="middle" fill="rgba(255,255,255,.85)" font-family="system-ui,Segoe UI,Arial">home.renovation.reviews</text>
          #{vp_line}
        </svg>
      SVG
    end

    def escape(s)
      ::CGI.escapeHTML(s.to_s)
    end
  end
end
