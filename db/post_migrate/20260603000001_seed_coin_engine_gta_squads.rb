# frozen_string_literal: true

# v0.24.0 — Seed the GTA regional squads so the Squads feature ships with teams
# to join out of the box. Idempotent: only inserts a slug that isn't present,
# so re-running (or running after an admin hand-creates one) never duplicates.
class SeedCoinEngineGtaSquads < ActiveRecord::Migration[7.0]
  def up
    return unless table_exists?(:coin_engine_squads)
    squads = [
      { slug: 'downtown-toronto', name: 'Downtown Core',        region: 'GTA Central', icon: '🏙️', color: '#2563eb', description: 'Condo renos, heritage semis and laneway suites across the old city.' },
      { slug: 'north-york',       name: 'North York Builders',  region: 'GTA Central', icon: '🏗️', color: '#7c3aed', description: 'Bungalow pop-ups and custom rebuilds north of the 401.' },
      { slug: 'scarborough',      name: 'Scarborough Crew',     region: 'GTA East',    icon: '🌅', color: '#dc2626', description: 'Backsplits, basements and big-lot additions out east.' },
      { slug: 'etobicoke',        name: 'Etobicoke West',       region: 'GTA West',    icon: '🌊', color: '#0891b2', description: 'Lakeshore renos and Kingsway kitchens.' },
      { slug: 'mississauga',      name: 'Mississauga Makers',   region: 'GTA West',    icon: '🍁', color: '#ea580c', description: 'Square One to Port Credit — full-home remodels.' },
      { slug: 'brampton',         name: 'Brampton Build Squad', region: 'GTA West',    icon: '⚡', color: '#16a34a', description: 'Fast-growing Peel reno community.' },
      { slug: 'vaughan',          name: 'Vaughan Vanguard',     region: 'GTA North',   icon: '🏔️', color: '#9333ea', description: 'Woodbridge and Maple custom builds.' },
      { slug: 'markham',          name: 'Markham Modern',       region: 'GTA North',   icon: '✨', color: '#0d9488', description: 'Contemporary renos across York Region.' },
    ]
    now = Time.now
    squads.each do |s|
      next if select_value("SELECT 1 FROM coin_engine_squads WHERE slug = #{quote(s[:slug])} LIMIT 1")
      execute(<<~SQL)
        INSERT INTO coin_engine_squads
          (slug, name, region, icon, color, description, member_count, total_score, enabled, created_at, updated_at)
        VALUES
          (#{quote(s[:slug])}, #{quote(s[:name])}, #{quote(s[:region])}, #{quote(s[:icon])},
           #{quote(s[:color])}, #{quote(s[:description])}, 0, 0, TRUE, #{quote(now)}, #{quote(now)})
      SQL
    end
  end

  def down
    # Non-destructive: leave seeded squads in place (members may have joined).
  end
end
