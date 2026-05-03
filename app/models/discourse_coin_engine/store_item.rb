# frozen_string_literal: true

module DiscourseCoinEngine
  class StoreItem < ::ActiveRecord::Base
    self.table_name = 'coin_engine_store_items'

    KINDS      = %w[nft perk bundle presale].freeze
    UNLIMITED  = 0

    belongs_to :created_by, class_name: '::User', foreign_key: :created_by_user_id, optional: true

    validates :kind,  inclusion: { in: KINDS }
    validates :name,  presence: true, length: { maximum: 120 }
    validates :slug,  presence: true, length: { maximum: 140 }, uniqueness: true,
              format: { with: /\A[a-z0-9][a-z0-9-]{0,138}[a-z0-9]\z/, message: 'lowercase letters, digits, and hyphens only' }

    scope :active,    -> { where(active: true) }
    scope :featured,  -> { where(featured: true) }
    scope :for_sale,  -> { active.where('supply = 0 OR sold_count < supply') }
    scope :ordered,   -> { order(featured: :desc, position: :asc, id: :asc) }

    def sold_out?
      supply.to_i > UNLIMITED && sold_count.to_i >= supply.to_i
    end

    def remaining
      return nil if supply.to_i == UNLIMITED
      [supply.to_i - sold_count.to_i, 0].max
    end

    def price_sol
      price_sol_lamports.to_f / 1_000_000_000
    end

    def can_buy_with_reno?
      price_reno.to_i > 0
    end

    def can_buy_with_sol?
      price_sol_lamports.to_i > 0
    end

    def traits
      return {} if traits_json.blank?
      JSON.parse(traits_json) rescue {}
    end

    def serialize_for_user
      {
        id:           id,
        kind:         kind,
        name:         name,
        slug:         slug,
        description:  description,
        image_url:    image_url,
        mint_address: mint_address,
        price_reno:   price_reno.to_i,
        price_sol:    price_sol,
        price_sol_lamports: price_sol_lamports.to_i,
        supply:       supply.to_i,
        sold_count:   sold_count.to_i,
        remaining:    remaining,
        sold_out:     sold_out?,
        featured:     featured,
        traits:       traits,
        released_at:  released_at,
        expires_at:   expires_at,
        can_buy_with_reno: can_buy_with_reno?,
        can_buy_with_sol:  can_buy_with_sol?,
      }
    end
  end
end
