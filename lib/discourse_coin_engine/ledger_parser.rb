# frozen_string_literal: true

module DiscourseCoinEngine
  # Parses the public payment ledger topic body (markdown table) and returns
  # the most recent N entries as structured rows. The ledger format is:
  #
  # | Date (UTC) | Recipient | Wallet | Amount | Tx signature | Type | Notes |
  #
  # Rows above the first divider line (---) are header/intro and are skipped.
  class LedgerParser
    HEADER_LINE = /\| *Date.*Recipient.*Amount.*Tx signature.*Type.*Notes/i.freeze
    DIVIDER     = /^\s*\|[-: ]+\|/.freeze
    DATA_ROW    = /^\s*\|\s*(\d{4}-\d{2}-\d{2}|\(genesis\)|--)\s*\|/.freeze

    def initialize(topic_id:, limit: 50)
      @topic_id = topic_id.to_i
      @limit    = limit.to_i.clamp(1, 500)
    end

    def call
      first_post = ::Post.where(topic_id: @topic_id).order(:post_number).first
      return [] unless first_post

      raw = first_post.raw.to_s.lines
      data_rows = []
      in_table  = false
      raw.each do |line|
        if HEADER_LINE.match?(line)
          in_table = true
          next
        end
        next unless in_table
        next if DIVIDER.match?(line)
        next unless DATA_ROW.match?(line)
        cells = line.strip.split('|').map(&:strip).reject(&:empty?)
        next if cells.length < 6
        data_rows << {
          date:        cells[0],
          recipient:   cells[1],
          wallet:      cells[2],
          amount:      cells[3],
          tx_signature: cells[4],
          type:        cells[5],
          notes:       (cells[6] || '')
        }
      end

      data_rows.last(@limit).reverse
    end
  end
end
