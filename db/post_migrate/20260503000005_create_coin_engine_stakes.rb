# frozen_string_literal: true

# v0.12.2 / v0.12.3 - DEPRECATED stub.
# This migration originally tried to create coin_engine_stakes for SOL staking,
# but Phase 2 (20260430000001) already created a coin_engine_stakes table for
# in-platform $RENO staking with a different schema. To avoid the collision,
# SOL staking moved to a separate table: coin_engine_sol_stakes (created in
# 20260503000006_create_coin_engine_sol_stakes.rb). This file is kept as a
# no-op stub so the schema_migrations row for this timestamp can complete
# cleanly on installs that already partially ran the broken migration.

class CreateCoinEngineStakes < ActiveRecord::Migration[7.0]
  def up
    # no-op - SOL staking lives in coin_engine_sol_stakes (next migration)
  end

  def down
    # no-op - we never owned coin_engine_stakes (Phase 2 owns it)
  end
end
