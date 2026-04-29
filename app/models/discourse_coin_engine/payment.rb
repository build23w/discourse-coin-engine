# frozen_string_literal: true

module DiscourseCoinEngine
  class Payment < ::ActiveRecord::Base
    self.table_name = 'coin_engine_payments'

    belongs_to :user
    belongs_to :issued_by, class_name: '::User', foreign_key: :issued_by_user_id, optional: true

    validates :user_id, presence: true
    validates :amount,  presence: true, numericality: { only_integer: true }
    validates :status,  inclusion: { in: %w[pending approved sent on_chain corrected reversed] }

    scope :recent,    -> { order(created_at: :desc) }
    scope :for_user,  ->(user_id) { where(user_id: user_id) }
    scope :on_chain,  -> { where.not(tx_signature: nil) }
    scope :pre_chain, -> { where(tx_signature: nil) }
  end
end
