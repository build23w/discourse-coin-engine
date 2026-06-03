# frozen_string_literal: true

# v0.25.0 — Public, shareable squad page at /coin-engine/squad/:slug.
# Server-rendered standalone HTML (self-contained styles + OpenGraph tags) so
# every squad has its own linkable "social" page that previews when shared and
# is crawlable for SEO. The rich interactive experience lives in the theme; this
# is the durable, shareable surface.
module DiscourseCoinEngine
  class SquadController < ::ApplicationController
    layout false
    skip_before_action :check_xhr, raise: false
    skip_before_action :redirect_to_login_if_required, raise: false

    def show
      squad = Squad.enabled.find_by(slug: params[:slug])
      raise ::Discourse::NotFound unless squad

      memberships = SquadMembership.where(squad_id: squad.id).limit(60).pluck(:user_id, :role, :joined_at)
      uids = memberships.map(&:first)
      users = ::User.where(id: uids).select(:id, :username, :name, :uploaded_avatar_id)
      totals = ::DiscourseCoinEngine.coin_user_total_bulk(uids)
      members = memberships.map do |id, role, joined|
        u = users.detect { |x| x.id == id }
        next nil unless u
        { username: u.username, name: u.name, role: role, score: (totals[id] || 0).to_i,
          avatar: u.avatar_template }
      end.compact.sort_by { |m| -m[:score] }
      rank = Squad.enabled.where('total_score > ?', squad.total_score.to_i).count + 1

      render html: build_page(squad, members, rank).html_safe, content_type: 'text/html', layout: false
    end

    private

    def coin_name
      (SiteSetting.coin_engine_coin_name rescue '$RENO').to_s
    end

    def h(s)
      ::CGI.escapeHTML(s.to_s)
    end

    def avatar_url(template)
      return nil if template.blank?
      url = template.gsub('{size}', '80')
      url.start_with?('http') ? url : "#{::Discourse.base_url}#{url}"
    end

    def build_page(squad, members, rank)
      coin = coin_name
      base = ::Discourse.base_url
      title = "#{squad.name} - #{coin} Squad"
      desc = (squad.description.presence || "A #{coin} squad on home.renovation.reviews - #{squad.member_count} members, #{squad.total_score} #{coin} together.").to_s[0, 200]
      accent = (squad.color.presence || '#4f46e5')
      icon = (squad.icon.presence || "\u{1F3D8}")

      rows = members.map do |m|
        av = avatar_url(m[:avatar])
        badge = m[:role] == 'captain' ? "<span class=\"cap\">\u{1F451} Captain</span>" : ''
        avatar_html = av ? %(<img src="#{h(av)}" alt="" width="40" height="40" loading="lazy">) : %(<span class="ava-fallback">#{h(m[:name].to_s[0,1].presence || m[:username][0,1])}</span>)
        <<~ROW
          <li class="m">
            <a href="#{base}/u/#{h(m[:username])}" class="m-link">
              #{avatar_html}
              <span class="m-name"><strong>#{h(m[:name].presence || m[:username])}</strong>#{badge}<small>@#{h(m[:username])}</small></span>
            </a>
            <span class="m-score">#{m[:score].to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse} #{h(coin)}</span>
          </li>
        ROW
      end.join("\n")

      <<~HTML
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>#{h(title)}</title>
        <meta name="description" content="#{h(desc)}">
        <meta property="og:type" content="profile">
        <meta property="og:title" content="#{h(title)}">
        <meta property="og:description" content="#{h(desc)}">
        <meta property="og:url" content="#{base}/coin-engine/squad/#{h(squad.slug)}">
        <meta name="twitter:card" content="summary">
        <link rel="canonical" href="#{base}/coin-engine/squad/#{h(squad.slug)}">
        <style>
          :root{--accent:#{accent};}
          *{box-sizing:border-box;margin:0;padding:0}
          body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;background:#f4f6f9;color:#0f1624;line-height:1.5}
          .wrap{max-width:680px;margin:0 auto;padding:20px}
          .hero{border-radius:18px;padding:30px 24px;color:#fff;background:linear-gradient(135deg,var(--accent),#0f1624);text-align:center;box-shadow:0 10px 30px rgba(0,0,0,.12)}
          .hero .ic{font-size:54px;line-height:1}
          .hero h1{font-size:28px;font-weight:800;margin:10px 0 4px}
          .hero .reg{opacity:.85;font-size:13px;text-transform:uppercase;letter-spacing:.06em}
          .hero .desc{margin:14px auto 0;max-width:460px;font-size:15px;opacity:.95}
          .stats{display:grid;grid-template-columns:repeat(3,1fr);gap:10px;margin:18px 0}
          .stat{background:#fff;border:1px solid #e7ebf0;border-radius:14px;padding:16px;text-align:center}
          .stat b{display:block;font-size:24px;font-weight:800}
          .stat span{font-size:11px;color:#5a6573;text-transform:uppercase;letter-spacing:.04em}
          .cta{display:block;text-align:center;background:var(--accent);color:#fff;text-decoration:none;font-weight:700;padding:14px;border-radius:12px;margin:6px 0 22px}
          h2{font-size:14px;text-transform:uppercase;letter-spacing:.05em;color:#5a6573;margin:0 0 10px}
          ul{list-style:none}
          .m{display:flex;align-items:center;justify-content:space-between;gap:10px;background:#fff;border:1px solid #e7ebf0;border-radius:12px;padding:10px 14px;margin-bottom:8px}
          .m-link{display:flex;align-items:center;gap:11px;text-decoration:none;color:inherit;min-width:0}
          .m-link img,.ava-fallback{width:40px;height:40px;border-radius:50%;flex:none}
          .ava-fallback{background:var(--accent);color:#fff;display:flex;align-items:center;justify-content:center;font-weight:700;text-transform:uppercase}
          .m-name{display:flex;flex-direction:column;min-width:0}
          .m-name strong{font-size:14px}
          .m-name small{color:#8b95a3;font-size:12px}
          .cap{display:inline-block;font-size:10px;font-weight:700;color:var(--accent);margin-left:0}
          .m-score{font-weight:800;font-size:14px;white-space:nowrap}
          footer{text-align:center;color:#9aa4b2;font-size:12px;margin:24px 0}
          footer a{color:#5a6573}
        </style>
        </head>
        <body>
        <div class="wrap">
          <div class="hero">
            <div class="ic">#{h(icon)}</div>
            <h1>#{h(squad.name)}</h1>
            #{squad.region.present? ? %(<div class="reg">#{h(squad.region)}</div>) : ''}
            #{squad.description.present? ? %(<p class="desc">#{h(squad.description)}</p>) : ''}
          </div>
          <div class="stats">
            <div class="stat"><b>##{rank}</b><span>Board rank</span></div>
            <div class="stat"><b>#{squad.member_count}</b><span>Members</span></div>
            <div class="stat"><b>#{squad.total_score.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse}</b><span>#{h(coin)}</span></div>
          </div>
          <a class="cta" href="#{base}/">Join #{h(squad.name)} on the forum &rarr;</a>
          <h2>Members</h2>
          <ul>#{rows}</ul>
          <footer>A #{h(coin)} squad on <a href="#{base}/">home.renovation.reviews</a></footer>
        </div>
        </body>
        </html>
      HTML
    end
  end
end
