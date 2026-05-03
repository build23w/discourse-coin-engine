# frozen_string_literal: true

# v0.11.0 — AR model for coin_engine_withdraw_requests.

module DiscourseCoinEngine
  class WithdrawRequest < ::ActiveRecord::Base
    self.table_name = 'coin_engine_withdraw_requests'

    STATUSES = %w[pending approved rejected cancelled].freeze

    belongs_to :user, class_name: '::User'
    belongs_to :decided_by, class_name: '::User', foreign_key: :decided_by_user_id, optional: true

    validates :user_id, presence: true
    validates :amount,  numericality: { greater_than: 0 }
    validates :status,  inclusion: { in: STATUSES }
    validates :wallet_address, presence: true, length: { maximum: 64 }

    scope :pending,    -> { where(status: 'pending') }
    scope :decided,    -> { where.not(status: 'pending') }
    scope :recent,     -> { order(created_at: :desc) }

    def pending?;   status == 'pending';   end
    def approved?;  status == 'approved';  end
    def rejected?;  status == 'rejected';  end
    def cancelled?; status == 'cancelled'; end
  end
end
