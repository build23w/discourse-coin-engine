# frozen_string_literal: true

# v0.18.10 — Server-rendered noscript profile content for SEO + accessibility.
#
# Renders a <noscript>-wrapped block of HTML containing the user's username,
# display name, bio, joined date, recent posts (with linked titles + excerpts),
# and stats. The block is included in every /u/{username}(/summary|/activity|
# /badges) response via register_html_builder("before-body-close").
#
# Why this matters:
#   - Bots that don't execute JS (older crawlers, archive.org, RSS aggregators
#     that follow links, social-share preview fetchers) can still see the
#     user's recent posts and link to them.
#   - JS-enabled browsers honor <noscript> by not rendering it; the SPA
#     shows our gamified hero in its place.
#   - Discourse's stock crawler view already shows a basic user summary,
#     but it doesn't surface the user's actual recent posts as clickable
#     links — this module does. That's a real SEO win for active members
#     whose profile pages get crawled.
#
# Performance:
#   ProfileBuilder.build is 60s-cached per user, so the noscript HTML
#   is essentially free to render on hot paths.
#
# Failure mode:
#   Any exception inside the renderer returns an empty string — we never
#   want a noscript bug to break the user's profile page entirely.

module DiscourseCoinEngine
  module ProfileNoscriptRenderer
    module_function

    USER_ROUTE_RE = %r{\A/u(?:sers)?/([^/?\#]+)(?:/(summary|activity|badges|notifications|preferences|messages))?/?\z}i

    # Entry point — receives the request controller from the html_builder
    # callback, decides if we're on a user route, and renders if so.
    def render_for_request(controller)
      return '' unless controller && controller.respond_to?(:request)
      path = controller.request.path.to_s
      m = path.match(USER_ROUTE_RE)
      return '' unless m

      username = m[1]
      subroute = (m[2] || 'summary').downcase
      # Only render for the views where our SPA hero appears
      return '' unless %w[summary activity badges].include?(subroute)

      user = ::User.find_by(username_lower: username.to_s.downcase)
      return '' unless user
      return '' if user.suspended? || user.silenced?
      # v0.18.11 — Drop the user.active? check. Some perfectly-real
      # established accounts have active=false flag for legacy reasons
      # (e.g. SSO-imported users). The suspended? + silenced? checks
      # already handle the actual abuse cases.

      Rails.logger.info("[coin_engine.profile_noscript] rendering for user=#{user.id} username=#{user.username} subroute=#{subroute}")
      build_html(user, subroute: subroute)
    rescue StandardError => e
      Rails.logger.warn("[coin_engine.profile_noscript] render failed: #{e.class}: #{e.message[0,200]}")
      ''
    end

    def build_html(user, subroute: 'summary')
      profile = ::DiscourseCoinEngine::ProfileBuilder.build(user) || {}

      out = +''
      out << '<noscript>'
      out << '<div class="lf-ux-noscript-profile" style="max-width:760px;margin:18px auto;padding:18px;font-family:system-ui,sans-serif;line-height:1.55;color:#0f1624">'

      # ----- Header -----
      out << "<h1 style=\"margin:0 0 4px;font-size:22px\">#{escape(user.username)}</h1>"
      out << "<p style=\"margin:0 0 6px;color:#5a6573\">#{escape(user.name)}</p>" if user.name.to_s.strip.present?
      title_line = profile[:title].to_s.strip
      out << "<p style=\"margin:0 0 6px\"><strong>#{escape(title_line)}</strong></p>" if title_line.present?

      if profile[:location].to_s.strip.present?
        out << "<p style=\"margin:0 0 4px;color:#5a6573\">#{escape(profile[:location])}</p>"
      end

      if profile[:joined_at].present?
        joined = Time.parse(profile[:joined_at].to_s).strftime('%B %Y') rescue profile[:joined_at]
        out << "<p style=\"margin:0 0 12px;color:#94a3b8;font-size:13px\">Member since #{escape(joined)}</p>"
      end

      # ----- Bio -----
      bio = profile[:bio_excerpt].to_s.strip
      if bio.present?
        out << '<section style="margin:16px 0">'
        out << '<h2 style="margin:0 0 6px;font-size:14px;text-transform:uppercase;letter-spacing:.5px;color:#5a6573">About</h2>'
        out << "<p style=\"margin:0\">#{escape(bio)}</p>"
        out << '</section>'
      end

      # ----- Stats -----
      stats = build_stats_line(profile, user)
      if stats.present?
        out << '<section style="margin:14px 0">'
        out << '<h2 style="margin:0 0 6px;font-size:14px;text-transform:uppercase;letter-spacing:.5px;color:#5a6573">Stats</h2>'
        out << "<p style=\"margin:0\">#{stats}</p>"
        out << '</section>'
      end

      # ----- Recent posts -----
      posts = profile[:recent_posts] || []
      if posts.any?
        out << '<section style="margin:16px 0">'
        out << '<h2 style="margin:0 0 6px;font-size:14px;text-transform:uppercase;letter-spacing:.5px;color:#5a6573">Recent posts</h2>'
        out << '<ol style="padding-left:20px;margin:0">'
        posts.first(10).each do |p|
          out << '<li style="margin-bottom:12px">'
          out << "<a href=\"#{escape(p[:url])}\" style=\"color:#d9560c;font-weight:700;text-decoration:none\">#{escape(p[:topic_title])}</a>"
          if p[:category_name].present?
            out << " <span style=\"color:#94a3b8;font-size:12px\">in #{escape(p[:category_name])}</span>"
          end
          if p[:created_at].present?
            ts = Time.parse(p[:created_at].to_s).strftime('%b %-d, %Y') rescue p[:created_at]
            out << " <span style=\"color:#94a3b8;font-size:12px\">· #{escape(ts)}</span>"
          end
          excerpt = p[:excerpt].to_s.strip
          if excerpt.present?
            out << "<p style=\"margin:4px 0 0;color:#0f1624;font-size:13.5px\">#{escape(excerpt[0, 220])}#{excerpt.length > 220 ? '…' : ''}</p>"
          end
          out << '</li>'
        end
        out << '</ol></section>'
      end

      # ----- Footer link to JS-enabled view -----
      out << "<p style=\"margin:18px 0 0;color:#94a3b8;font-size:12px\">"
      out << "This is a fallback view. <a href=\"/u/#{escape(user.username)}\" style=\"color:#d9560c\">Open the full profile</a> with JavaScript enabled to see live stats, badges, and the gamified view."
      out << '</p>'

      out << '</div>'
      out << '</noscript>'
      out.html_safe
    end

    # Compose a simple "Posts: X · Topics: Y · Likes: Z · ..." line.
    def build_stats_line(profile, user)
      parts = []
      coin = (SiteSetting.coin_engine_coin_name rescue '$RENO').to_s
      parts << "#{coin}: #{profile[:score].to_i}" if profile[:score].to_i > 0
      parts << "Rank: ##{profile[:rank].to_i}"    if profile[:rank].to_i  > 0
      parts << "Streak: #{profile[:streak].to_i}d" if profile[:streak].to_i > 0
      parts << "Posts: #{profile[:posts_count].to_i}"   if profile[:posts_count].to_i > 0
      parts << "Topics: #{profile[:topics_count].to_i}" if profile[:topics_count].to_i > 0
      parts << "Likes received: #{profile[:likes_received].to_i}" if profile[:likes_received].to_i > 0
      parts << "Days visited: #{profile[:days_visited].to_i}" if profile[:days_visited].to_i > 0
      parts.map { |s| escape(s) }.join(' · ')
    end

    def escape(s)
      ::ERB::Util.html_escape(s.to_s)
    end
  end
end
