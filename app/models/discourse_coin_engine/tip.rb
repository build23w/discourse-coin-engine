# frozen_string_literal: true
module DiscourseCoinEngine
  class Tip < ::ActiveRecord::Base
    self.table_name = 'coin_engine_tips'
    belongs_to :sender,    class_name: '::User', foreign_key: :sender_user_id
    belongs_to :recipient, class_name: '::User', foreign_key: :recipient_user_id
    belongs_to :post, optional: true
    validates :amount, presence: true, numericality: { greater_than: 0 }
    validates :sender_user_id, presence: true
    validates :recipient_user_id, presence: true
    validate  :no_self_tip
    private
    def no_self_tip
      errors.add(:base, 'cannot tip yourself') if sender_user_id == recipient_user_id
    end
  end
end
