# frozen_string_literal: true
module DiscourseCoinEngine
  class Repost < ::ActiveRecord::Base
    self.table_name = 'coin_engine_reposts'
    KINDS = %w[short topic].freeze
    validates :user_id, :kind, :ref_id, presence: true
    validates :kind, inclusion: { in: KINDS }
    validates :user_id, uniqueness: { scope: %i[kind ref_id] }
  end
end
