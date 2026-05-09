# frozen_string_literal: true

# v0.19.2 — INTENTIONALLY EMPTY.
#
# This file previously contained DiscourseCoinEngine::LeaderboardLiveQueryPatch
# (v0.19.0/v0.19.1), which monkey-patched DiscourseGamification::LeaderboardCachedView#scores
# to bypass the materialized view and return a live SUM(gamification_scores).
#
# That approach was reverted because:
#   1. Lifetime SUM breaks period leaderboards (yearly/monthly/etc.) — those WANT
#      a date-filtered view, that's the whole point of the period selector.
#   2. Lifetime SUM breaks private/per-category leaderboards that filter by user
#      permissions or category scope.
#   3. Conflating gamification XP with $RENO rewards (via credit_score writing
#      to gamification_scores) creates a tip-to-the-top abuse vector. The fix
#      isn't to make the leaderboard live, it's to keep $RENO out of
#      gamification_scores so the leaderboard reflects native scoring only.
#
# Going back to classic discourse-gamification MV-based leaderboard. The FAB
# splits "leaderboard score" and "$RENO balance" into two distinct displays so
# the UX no longer pretends they're the same number.
#
# This file is kept as a tombstone rather than deleted so git history remains
# linear. plugin.rb does NOT load it.
