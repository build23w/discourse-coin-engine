# frozen_string_literal: true

# v0.27.0 — On-chain peer-to-peer SOL tip (table coin_engine_sol_tips).
module DiscourseCoinEngine
  class SolTip < ::ActiveRecord::Base
    self.table_name = 'coin_engine_sol_tips'

    STATUSES = %w[pending confirmed failed].freeze

    belongs_to :sender,    class_name: '::User', foreign_key: :sender_user_id
    belongs_to :recipient, class_name: '::User', foreign_key: :recipient_user_id

    validates :sender_user_id, :recipient_user_id, presence: true
    validates :amount_lamports, numericality: { greater_than: 0 }
    validates :recipient_wallet, presence: true, length: { maximum: 64 }
    validates :status, inclusion: { in: STATUSES }

    scope :confirmed, -> { where(status: 'confirmed') }
    scope :for_recipient, ->(uid) { where(recipient_user_id: uid) }
    scope :recent, -> { order(created_at: :desc) }

    def amount_sol
      amount_lamports.to_f / 1_000_000_000
    end

    def metadata
      return {} if metadata_json.blank?
      JSON.parse(metadata_json) rescue {}
    end

    def serialize_for_user
      {
        id: id, amount_lamports: amount_lamports.to_i, amount_sol: amount_sol,
        recipient_wallet: recipient_wallet, tx_signature: tx_signature, status: status,
        post_id: post_id, confirmed_at: confirmed_at, created_at: created_at
      }
    end
  end
end
