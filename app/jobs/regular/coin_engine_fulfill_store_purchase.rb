# frozen_string_literal: true

# v0.12.0 - Delivers a paid purchase to the user.
#
# For 'item' purchases:
#   - 'perk' kind: grants the perk (custom title, badge, etc.) via metadata.
#   - 'nft'  kind: queues an admin task to manually transfer the NFT, OR if
#     coin_engine_nft_auto_fulfill is true, calls into the (TBD) treasury
#     signing flow.
# For 'reno_presale' purchases:
#   - Sends a system PM noting "you paid X SOL, you'll receive Y $RENO once
#     admin processes the queue" - admin runs the on-chain mint manually
#     for now (full automation requires a treasury keypair on the server).
#
# This job is intentionally idempotent and best-effort. Real on-chain
# fulfillment lives outside this job until the treasury keypair flow lands.

module Jobs
  class CoinEngineFulfillStorePurchase < ::Jobs::Base
    sidekiq_options retry: 3

    def execute(args)
      purchase_id = args[:purchase_id].to_i
      return if purchase_id <= 0
      pp = ::DiscourseCoinEngine::StorePurchase.find_by(id: purchase_id)
      return unless pp
      return if pp.status == 'fulfilled'
      return unless %w[paid].include?(pp.status)

      case pp.kind
      when 'item'
        fulfill_item(pp)
      when 'reno_presale'
        notify_presale(pp)
      end
    rescue StandardError => e
      Rails.logger.error("[coin_engine] fulfill_store_purchase failed for #{args[:purchase_id]}: #{e.class}: #{e.message}")
      raise
    end

    private

    def fulfill_item(pp)
      item = pp.item
      return unless item

      case item.kind
      when 'perk'
        apply_perk!(pp, item)
        pp.update!(status: 'fulfilled', fulfilled_at: Time.zone.now)
      when 'bundle'
        apply_perk!(pp, item)
        pp.update!(status: 'fulfilled', fulfilled_at: Time.zone.now)
      when 'nft'
        # NFT transfer requires admin signing OR treasury keypair on server.
        # Status stays 'paid' until admin marks fulfilled in the admin panel.
        # Send the user a confirmation PM so they know it's coming.
        send_purchase_confirmation_pm(pp, item, "Your NFT will be transferred to your wallet within 24h.")
      else
        send_purchase_confirmation_pm(pp, item, "Your purchase has been recorded.")
      end
    end

    def apply_perk!(pp, item)
      traits = item.traits
      user = pp.user
      return unless user
      # Examples of perks the admin can grant via traits_json:
      #   { "title": "OG Holder" }
      #   { "badge_id": 142 }
      #   { "reno_credit": 10000 }
      if (t = traits['title']).is_a?(String) && t.present?
        user.update_columns(title: t.to_s[0, 60])
      end
      if (bid = traits['badge_id']).to_i > 0
        ::UserBadge.find_or_create_by(user_id: user.id, badge_id: bid.to_i, granted_at: Time.zone.now, granted_by_id: ::Discourse.system_user.id)
      end
      if (credit = traits['reno_credit']).to_i > 0
        ::DiscourseCoinEngine.credit_score(user.id, Date.today, credit.to_i)
      end
    end

    def notify_presale(pp)
      meta = pp.metadata
      expected = meta['expected_reno'].to_i
      msg = "Your $RENO presale purchase is confirmed.\n\n" \
            "- Paid: **#{(pp.amount_paid.to_f / 1_000_000_000).round(4)} SOL**\n" \
            "- Expected: **#{expected.to_s.reverse.gsub(/...(?=.)/, '\&,').reverse} $RENO**\n" \
            "- Tx: `#{pp.tx_signature}`\n\n" \
            "An admin will mint the tokens to your wallet within 1-2 business days. " \
            "Tokens go directly to your linked Solana wallet — they do **not** count toward your community $RENO balance."
      ::PostCreator.create!(
        ::Discourse.system_user,
        title: "$RENO presale purchase ##{pp.id} confirmed",
        raw: msg,
        archetype: ::Archetype.private_message,
        target_usernames: pp.user.username,
        skip_validations: true,
      )
    rescue StandardError => e
      Rails.logger.error("[coin_engine] presale notify failed: #{e.message}")
    end

    def send_purchase_confirmation_pm(pp, item, footer)
      msg = "Purchase confirmed: **#{item.name}**\n\n" \
            "- Order: ##{pp.id}\n" \
            "- Paid: #{pp.currency == 'reno' ? "#{pp.amount_paid} $RENO" : "#{(pp.amount_paid.to_f/1_000_000_000).round(4)} SOL"}\n" \
            "#{pp.tx_signature ? "- Tx: `#{pp.tx_signature}`\n" : ''}" \
            "\n#{footer}"
      ::PostCreator.create!(
        ::Discourse.system_user,
        title: "Purchase ##{pp.id} confirmed: #{item.name}",
        raw: msg,
        archetype: ::Archetype.private_message,
        target_usernames: pp.user.username,
        skip_validations: true,
      )
    rescue StandardError => e
      Rails.logger.error("[coin_engine] purchase PM failed: #{e.message}")
    end
  end
end
