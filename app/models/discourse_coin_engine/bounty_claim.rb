# frozen_string_literal: true

module DiscourseCoinEngine
  class BountyClaim < ::ActiveRecord::Base
    self.table_name = 'coin_engine_bounty_claims'
  end
end
