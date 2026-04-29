# frozen_string_literal: true

module DiscourseCoinEngine
  # Server-side daily-visit streak. Reads from user_visits.visited_at (one row per
  # user per visit-day after the once-daily collapse). The current streak is the
  # number of consecutive days back from today (or yesterday, if no visit today).
  class StreakCalculator
    def initialize(user_id:)
      @user_id = user_id.to_i
    end

    def current
      return 0 unless @user_id > 0
      dates = visit_dates
      return 0 if dates.empty?

      # If user visited today, anchor is today; else if yesterday, anchor is yesterday;
      # else streak is broken.
      anchor =
        if dates.include?(Date.today)        then Date.today
        elsif dates.include?(Date.today - 1) then Date.today - 1
        else return 0
        end

      streak = 0
      day = anchor
      set = dates.to_set
      while set.include?(day)
        streak += 1
        day -= 1
      end
      streak
    end

    def longest
      return 0 unless @user_id > 0
      dates = visit_dates.sort
      return 0 if dates.empty?
      best = run = 1
      (1...dates.length).each do |i|
        run = (dates[i] - dates[i - 1]).to_i == 1 ? run + 1 : 1
        best = run if run > best
      end
      best
    end

    def last_visit_at
      ::UserVisit.where(user_id: @user_id).order(visited_at: :desc).limit(1).pluck(:visited_at).first
    rescue StandardError
      nil
    end

    # The streak is "at risk" when the user has not visited today AND yesterday they did.
    def at_risk?
      dates = visit_dates
      return false if dates.empty?
      !dates.include?(Date.today) && dates.include?(Date.today - 1)
    end

    private

    def visit_dates
      @visit_dates ||=
        begin
          ::UserVisit.where(user_id: @user_id)
                     .where('visited_at >= ?', 400.days.ago)
                     .pluck(:visited_at)
                     .map { |t| t.to_date }
                     .uniq
        rescue StandardError
          []
        end
    end
  end
end
