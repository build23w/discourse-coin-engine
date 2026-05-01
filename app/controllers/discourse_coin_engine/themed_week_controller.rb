# frozen_string_literal: true

# Themed Week endpoint — returns the currently-active themed-week config.
#
# Drives the "this week's theme" widget in hrr-ux-pack: highlights a category,
# offers bonus $RENO multiplier, displays a banner.
#
# All driven by site settings; admins rotate themes by editing the settings
# (or, in a future rev, via a scheduled job that picks from a pool).
module DiscourseCoinEngine
  class ThemedWeekController < ::ApplicationController
    skip_before_action :preload_json
    skip_before_action :check_xhr

    def show
      return render json: { active: false }, status: 200 unless SiteSetting.coin_engine_enabled

      cat_id   = SiteSetting.coin_engine_themed_week_category_id.to_i
      name     = SiteSetting.coin_engine_themed_week_name.to_s
      mult     = SiteSetting.coin_engine_themed_week_multiplier.to_f
      ends_at  = SiteSetting.coin_engine_themed_week_ends_at.to_s
      tagline  = SiteSetting.coin_engine_themed_week_tagline.to_s
      hashtag  = SiteSetting.coin_engine_themed_week_hashtag.to_s

      active = name.present? && (cat_id > 0 || hashtag.present?)
      cat = active && cat_id > 0 ? Category.find_by(id: cat_id) : nil

      render json: {
        active: active,
        name: name,
        tagline: tagline,
        hashtag: hashtag,
        multiplier: mult > 0 ? mult : 1.5,
        ends_at: ends_at.presence,
        category: cat && {
          id: cat.id,
          name: cat.name,
          slug: cat.slug,
          color: cat.color,
          url: "/c/#{cat.slug}/#{cat.id}",
        },
      }
    end
  end
end
