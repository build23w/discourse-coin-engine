# frozen_string_literal: true
# Squad HQ: link a squad to its auto-created Discourse subcategory + mirror group.
class AddSquadHqColumns < ActiveRecord::Migration[7.0]
  def change
    add_column :coin_engine_squads, :category_id, :integer unless column_exists?(:coin_engine_squads, :category_id)
    add_column :coin_engine_squads, :group_id, :integer unless column_exists?(:coin_engine_squads, :group_id)
  end
end
