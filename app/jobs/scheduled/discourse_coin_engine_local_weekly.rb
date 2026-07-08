# frozen_string_literal: true

module Jobs
  # v0.35.0 - "Your area this week" engine. Once a week, for each city with
  # enough located members, publish a roundup topic of the hottest local
  # threads. Gives the geo digests a landing page, gives new local members
  # instant social proof, and gives search engines city-level fresh content.
  #
  # Category resolution per city: category named after the city -> category
  # named after the province -> coin_engine_local_weekly_category_id -> the
  # poster's default (uncategorized).
  class DiscourseCoinEngineLocalWeekly < ::Jobs::Scheduled
    every 1.week

    STORE = 'discourse-coin-engine'

    def execute(args)
      return unless SiteSetting.coin_engine_enabled
      return unless SiteSetting.coin_engine_local_weekly_enabled

      poster = resolve_poster
      return if poster.nil?

      min_users  = SiteSetting.coin_engine_local_weekly_min_users.to_i.clamp(1, 1000)
      max_cities = SiteSetting.coin_engine_local_weekly_max_cities.to_i.clamp(1, 50)

      cities_with_counts(min_users).first(max_cities).each do |city_key, sample_location, count|
        begin
          publish_for_city(poster, city_key, sample_location, count)
        rescue StandardError => e
          Rails.logger.warn "[coin-engine] local weekly failed for #{city_key}: #{e.message}"
        end
      end
    end

    private

    def resolve_poster
      name = SiteSetting.coin_engine_local_weekly_username.to_s.strip
      name = SiteSetting.site_contact_username.to_s.strip if name.blank?
      (name.present? && ::User.find_by(username_lower: name.downcase)) || ::Discourse.system_user
    end

    # [[city_key(lowercased), sample_full_location, member_count], ...] by count desc
    def cities_with_counts(min_users)
      counts = Hash.new(0)
      sample = {}
      ::UserProfile.where.not(location: [nil, ''])
                   .joins(:user)
                   .where(users: { staged: false, active: true })
                   .pluck(:location)
                   .each do |loc|
        city = loc.to_s.split(',').first.to_s.strip
        next if city.blank? || city.length < 3
        k = city.downcase
        counts[k] += 1
        sample[k] ||= loc
      end
      counts.select { |_k, c| c >= min_users }
            .sort_by { |_k, c| -c }
            .map { |k, c| [k, sample[k], c] }
    end

    def publish_for_city(poster, city_key, sample_location, member_count)
      store_key = "local_weekly_#{city_key.parameterize}"
      prev = ::PluginStore.get(STORE, store_key)
      if prev && prev['at'].present?
        return if (Time.parse(prev['at'].to_s) > 6.days.ago rescue false) # this week's already out
      end

      rows = ::DiscourseCoinEngine::GeoDigest.topics_for_location(sample_location, limit: 8, since: 7.days.ago)
      return if rows.length < 2 # not enough local action for a roundup

      city_display = city_key.split(/\s+/).map(&:capitalize).join(' ')
      title = "#{city_display} this week - local reno roundup (#{Date.today.strftime('%b %-d, %Y')})"

      raw = +"What's been happening around **#{city_display}** this week - the local threads with the most action:\n\n"
      rows.each do |id, t, slug, views, posts, _likes|
        raw << "- [#{t}](/t/#{slug}/#{id}) - #{[posts.to_i - 1, 0].max} replies, #{views.to_i} views\n"
      end
      raw << "\n---\n"
      raw << "*#{member_count} members near #{city_display} get their digest from this area. "
      raw << "New here? [Set your location](/my/preferences/profile) and your feed, digests and "
      raw << "recommendations go local - there's #{SiteSetting.coin_engine_coin_name} in it for you.*\n"

      opts = { title: title, raw: raw, skip_validations: true }
      if (cat_id = resolve_category(city_key, sample_location))
        opts[:category] = cat_id
      end

      creator = ::PostCreator.new(poster, **opts)
      post = creator.create
      if post&.topic_id
        ::PluginStore.set(STORE, store_key,
                          'topic_id' => post.topic_id, 'at' => Time.now.iso8601, 'city' => city_display)
      elsif creator.errors.any?
        Rails.logger.warn "[coin-engine] local weekly PostCreator errors for #{city_key}: #{creator.errors.full_messages.join(', ')}"
      end
    end

    def resolve_category(city_key, sample_location)
      c = ::Category.where('lower(name) = ?', city_key).first
      return c.id if c
      province = sample_location.to_s.split(',')[1].to_s.strip.downcase
      if province.present?
        c = ::Category.where('lower(name) = ?', province).first
        return c.id if c
      end
      configured = SiteSetting.coin_engine_local_weekly_category_id.to_i
      configured > 0 ? configured : nil
    end
  end
end
