# frozen_string_literal: true

module Jobs
  # v0.33.0 — Weekly "Top Builders" recap TOPIC (community ritual + SEO page).
  # Posts the week's top-10 $RENO earners as a public topic every week. Inert
  # until coin_engine_weekly_recap_category_id points at a real category.
  class DiscourseCoinEngineWeeklyRecapTopic < ::Jobs::Scheduled
    every 1.week

    def execute(args)
      return unless SiteSetting.coin_engine_enabled
      return unless SiteSetting.coin_engine_weekly_recap_topic_enabled
      cat_id = SiteSetting.coin_engine_weekly_recap_category_id.to_i
      return if cat_id <= 0
      return unless ::Category.exists?(id: cat_id)

      top = ::DiscourseCoinEngine::LeaderboardQuery.new(period: 'week', limit: 10).call
      return if top.blank? || top.size < 3

      coin = (SiteSetting.coin_engine_coin_name rescue '$RENO').to_s
      week_label = Time.zone.now.strftime('%b %-d, %Y')
      rows = top.each_with_index.map do |r, i|
        medal = %w[🥇 🥈 🥉][i] || "##{i + 1}"
        "| #{medal} | @#{r[:username]} | #{r[:score] || r[:total_score]} #{coin} |"
      end.join("\n")

      raw = <<~MD
        Every week the community's most helpful builders rise to the top — here's who earned the most #{coin} this week.

        | Rank | Builder | Earned |
        |---|---|---|
        #{rows}

        **How it works:** helpful replies, upvotes from neighbours, and quality topics all earn #{coin}. See where you stand on the [live leaderboard](/leaderboard) — and if a pro on this list helped you, their profile is one tap away.

        *Want on this list next week? The fastest route is answering an unanswered question — first helpful replies earn the most.*
      MD

      pc = ::PostCreator.new(
        ::Discourse.system_user,
        title: "Top Builders of the week — #{week_label}",
        raw: raw,
        category: cat_id,
        skip_validations: true
      )
      post = pc.create
      if pc.errors.present?
        Rails.logger.warn("[coin-engine] weekly recap topic failed: #{pc.errors.full_messages.join(', ')}")
      else
        Rails.logger.info("[coin-engine] weekly recap topic created: #{post&.topic_id}")
      end
    end
  end
end
