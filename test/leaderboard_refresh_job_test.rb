# frozen_string_literal: true

# Run without Rails to verify the scheduled job leaves the bundled hourly
# refresh alone while retaining a fallback if that job is unavailable.
class Integer
  def hour
    self * 3600
  end
end

module Jobs
  class Scheduled
    def self.every(interval)
      @interval = interval
    end

    def self.interval
      @interval
    end
  end

  class UpdateScoresForToday
  end
end

module SiteSetting
  def self.coin_engine_enabled
    true
  end

  def self.discourse_gamification_enabled
    true
  end
end

module Rails
  def self.cache
    @cache ||= Object.new.tap { |cache| def cache.delete(_key); end }
  end

  def self.logger
    @logger ||= Object.new.tap { |logger| def logger.info(_message); end }
  end
end

module ActiveRecord
  class StatementInvalid < StandardError
  end

  class Base
    def self.connection
      $test_connection
    end
  end
end

class TestConnection
  attr_reader :queries

  def initialize
    @queries = []
  end

  def execute(sql)
    @queries << sql
    return [{ "matviewname" => "gamification_leaderboard_cache_1_all_time" }] if sql.start_with?("SELECT matviewname")

    nil
  end
end

require_relative "../app/jobs/scheduled/discourse_coin_engine_refresh_leaderboard_views"

job_class = Jobs::DiscourseCoinEngineRefreshLeaderboardViews
raise "refresh job must run at most hourly" unless job_class.interval == 3600

$test_connection = TestConnection.new
job_class.new.execute({})
raise "bundled gamification should own refresh" unless $test_connection.queries.empty?

Jobs.send(:remove_const, :UpdateScoresForToday)
job_class.new.execute({})
raise "fallback must refresh a materialized view" unless $test_connection.queries.any? { |sql| sql.start_with?("REFRESH MATERIALIZED VIEW CONCURRENTLY") }

puts "leaderboard refresh job fallback and upstream skip pass"
