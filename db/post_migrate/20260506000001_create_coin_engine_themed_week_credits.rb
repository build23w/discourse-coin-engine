# frozen_string_literal: true

# v0.17.0 - Idempotency table for themed-week post bonuses. Without this,
# every edit to a qualifying post would re-fire the bonus (or we'd have to
# re-scan posts at runtime). One row per (post_id) once the credit lands.
class CreateCoinEngineThemedWeekCredits < ActiveRecord::Migration[7.0]
  def change
    create_table :coin_engine_themed_week_credits do |t|
      t.integer  :post_id,          null: false
      t.integer  :user_id,          null: false
      t.string   :themed_week_name, null: false, limit: 100
      t.integer  :amount,           null: false, default: 0
      t.string   :match_kind,       null: false, limit: 20  # "category" or "hashtag" or "both"
      t.timestamps
    end
    # post_id is the dedupe key — one bonus per post, ever.
    #
    # Postgres caps index identifiers at 63 chars; Rails' default name is
    # `index_<table>_on_<col1>_and_<col2>` which for this table + a compound
    # column blows past the limit. Use explicit short names so migrations
    # work on stock Postgres without bumping NAMEDATALEN.
    add_index :coin_engine_themed_week_credits, :post_id,
              unique: true, name: 'idx_themed_credits_post'
    add_index :coin_engine_themed_week_credits, [:themed_week_name, :user_id],
              name: 'idx_themed_credits_theme_user'
    add_index :coin_engine_themed_week_credits, :created_at,
              name: 'idx_themed_credits_created'
  end
end
