# frozen_string_literal: true

# Embeddable tier badge for any external site.
#
# Three flavors:
#   GET /coin-engine/embed/u/:username          -> minimal HTML (iframe-friendly)
#   GET /coin-engine/embed/u/:username.json     -> JSON for programmatic embed
#   GET /coin-engine/embed/u/:username.svg      -> SVG (works in <img> tag, GitHub-flavored markdown)
#
# Backlink play: every embed renders a "Powered by home.renovation.reviews"
# link, generating organic inbound links from contractors' own sites.
module DiscourseCoinEngine
  class EmbedController < ::ApplicationController
    skip_before_action :preload_json
    skip_before_action :check_xhr
    skip_before_action :redirect_to_login_if_required, raise: false
    skip_before_action :verify_authenticity_token

    def show
      return render plain: 'Coin engine disabled', status: 404 unless SiteSetting.coin_engine_enabled

      user = User.find_by(username_lower: params[:username].to_s.downcase)
      return render plain: 'User not found', status: 404 unless user

      @username    = user.username
      @display     = user.name.presence || user.username
      @avatar      = UrlHelper.absolute(user.avatar_template_url.gsub('{size}', '96'))
      @score       = ::DiscourseCoinEngine.coin_user_total(user.id)
      @tier        = ::DiscourseCoinEngine::TierResolver.new(@score).call rescue nil
      @rank        = lookup_rank(user.id)
      @brand       = SiteSetting.coin_engine_brand_color.presence || '#ff6b35'
      @coin        = SiteSetting.coin_engine_coin_name.presence || '$RENO'
      @site_name   = SiteSetting.title
      @site_host   = Discourse.current_hostname
      @profile_url = "https://#{@site_host}/coin-engine/u/#{@username}"

      respond_to do |format|
        format.html do
          # Layoutless, embeddable. Allow framing.
          response.headers.delete('X-Frame-Options')
          response.headers['Content-Security-Policy'] = "frame-ancestors *;"
          render layout: false
        end
        format.json do
          render json: {
            username: @username,
            display: @display,
            avatar: @avatar,
            score: @score,
            coin: @coin,
            tier: @tier,
            rank: @rank,
            profile_url: @profile_url,
            site: @site_name,
          }
        end
        format.svg do
          response.headers.delete('X-Frame-Options')
          send_data svg_badge, type: 'image/svg+xml', disposition: 'inline'
        end
      end
    end

    private

    def lookup_rank(user_id)
      # Canonical shared helper — same filter as the public leaderboard.
      ::DiscourseCoinEngine.rank_for(user_id)
    rescue StandardError
      nil
    end

    def svg_badge
      tier_name = @tier.is_a?(Hash) ? (@tier[:name] || @tier['name']) : (@tier || 'Member')
      score_str = @score.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse
      rank_str  = @rank ? "##{@rank}" : '—'
      brand     = @brand
      <<~SVG
        <svg xmlns="http://www.w3.org/2000/svg" width="240" height="60" viewBox="0 0 240 60">
          <defs>
            <linearGradient id="g" x1="0" x2="1" y1="0" y2="1">
              <stop offset="0" stop-color="#{brand}"/>
              <stop offset="1" stop-color="#0f1624"/>
            </linearGradient>
          </defs>
          <rect width="240" height="60" rx="10" fill="url(#g)"/>
          <text x="14" y="22" font-family="-apple-system,Segoe UI,Inter,Arial" font-size="11" font-weight="700" fill="rgba(255,255,255,0.85)" letter-spacing="0.6">#{escape(@coin.upcase)} TIER</text>
          <text x="14" y="42" font-family="-apple-system,Segoe UI,Inter,Arial" font-size="18" font-weight="800" fill="#fff">#{escape(tier_name)}</text>
          <text x="14" y="55" font-family="-apple-system,Segoe UI,Inter,Arial" font-size="9.5" fill="rgba(255,255,255,0.65)">#{escape(@display)}</text>
          <text x="226" y="22" text-anchor="end" font-family="-apple-system,Segoe UI,Inter,Arial" font-size="10" fill="rgba(255,255,255,0.7)">#{score_str} #{escape(@coin)}</text>
          <text x="226" y="42" text-anchor="end" font-family="-apple-system,Segoe UI,Inter,Arial" font-size="20" font-weight="800" fill="#fff">#{rank_str}</text>
          <text x="226" y="55" text-anchor="end" font-family="-apple-system,Segoe UI,Inter,Arial" font-size="9" fill="rgba(255,255,255,0.6)">#{escape(@site_host)}</text>
        </svg>
      SVG
    end

    def escape(s)
      ERB::Util.h(s.to_s)
    end
  end
end
