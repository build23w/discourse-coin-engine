# frozen_string_literal: true

module DiscourseCoinEngine
  class StorePurchase < ::ActiveRecord::Base
    self.table_name = 'coin_engine_store_purchases'

    KINDS      = %w[item reno_presale reno_swap].freeze
    CURRENCIES = %w[reno sol].freeze
    STATUSES   = %w[pending paid fulfilled refunded cancelled failed].freeze

    belongs_to :user, class_name: '::User'
    belongs_to :item, class_name: 'StoreItem', optional: true

    validates :kind,     inclusion: { in: KINDS }
    validates :currency, inclusion: { in: CURRENCIES }
    validates :status,   inclusion: { in: STATUSES }

    scope :recent,    -> { order(created_at: :desc) }
    scope :pending,   -> { where(status: 'pending') }
    scope :paid,      -> { where(status: %w[paid fulfilled]) }
    scope :fulfilled, -> { where(status: 'fulfilled') }

    def metadata
      return {} if metadata_json.blank?
      JSON.parse(metadata_json) rescue {}
    end

    def metadata=(hash)
      self.metadata_json = hash.to_json
    end

    def serialize_for_user
      {
        id:              id,
        kind:            kind,
        item_id:         item_id,
        currency:        currency,
        amount_paid:     amount_paid.to_i,
        amount_received: amount_received.to_i,
        wallet_used:     wallet_used,
        tx_signature:    tx_signature,
        status:          status,
        paid_at:         paid_at,
        fulfilled_at:    fulfilled_at,
        created_at:      created_at,
      }
    end
  end
end
