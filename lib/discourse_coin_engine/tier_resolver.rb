# frozen_string_literal: true

module DiscourseCoinEngine
  # Maps a coin total to a tier {name, threshold, next} based on the configured
  # pipe-separated tier_thresholds + tier_names site settings.
  class TierResolver
    DEFAULT_THRESHOLDS = [0, 100, 1000, 5000, 25000, 50000].freeze
    DEFAULT_NAMES      = %w[Beginner Bronze Silver Gold Platinum Diamond].freeze

    def initialize(score)
      @score = score.to_i
    end

    def call
      thresholds = SiteSetting.coin_engine_tier_thresholds.to_s.split('|').map { |v| v.strip.to_i } rescue DEFAULT_THRESHOLDS
      names      = SiteSetting.coin_engine_tier_names.to_s.split('|').map(&:strip)               rescue DEFAULT_NAMES
      thresholds = DEFAULT_THRESHOLDS if thresholds.length != names.length || thresholds.empty?
      names      = DEFAULT_NAMES      if thresholds.length != names.length || names.empty?

      i = thresholds.length - 1
      i -= 1 while i > 0 && @score < thresholds[i]

      next_min = thresholds[i + 1]
      {
        name: names[i],
        min:  thresholds[i],
        next_name: next_min ? names[i + 1] : nil,
        next_min:  next_min,
        to_next:   next_min ? [next_min - @score, 0].max : nil
      }
    end
  end
end
