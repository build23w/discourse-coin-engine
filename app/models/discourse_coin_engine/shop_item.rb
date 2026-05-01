# frozen_string_literal: true
module DiscourseCoinEngine
  class ShopItem < ::ActiveRecord::Base
    self.table_name = 'coin_engine_shop_items'
    has_many :redemptions, class_name: 'DiscourseCoinEngine::Redemption', foreign_key: :shop_item_id
    validates :slug, presence: true, uniqueness: true
    validates :name, presence: true
    validates :price, presence: true, numericality: { greater_than_or_equal_to: 0 }
    validates :item_type, presence: true
    scope :enabled, -> { where(enabled: true) }
    scope :in_stock, -> { where('stock = -1 OR stock > 0') }

    def in_stock?
      stock == -1 || stock > 0
    end
  end

  class Redemption < ::ActiveRecord::Base
    self.table_name = 'coin_engine_redemptions'
    belongs_to :user, class_name: '::User'
    belongs_to :shop_item, class_name: 'DiscourseCoinEngine::ShopItem', foreign_key: :shop_item_id
    scope :active, -> { where(status: 'active') }
  end
end
