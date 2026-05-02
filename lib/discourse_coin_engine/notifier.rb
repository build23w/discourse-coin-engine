# frozen_string_literal: true

# v0.8.4 — Cross-feature credit notifier.
#
# When a user receives $RENO via a tip, bounty award, redeem, airdrop, manual
# admin payment, etc. we:
#
#  1. Push a MessageBus event to /coin-engine/credits/:user_id so any open
#     tab in the recipient's browser updates the FAB balance + shows a toast
#     instantly. (Avoids waiting for a Sidekiq job or a page reload.)
#  2. Send a private message via PostCreator. Discourse routes PMs to email
#     for offline users automatically (subject to the user's notification
#     preferences), so we don't need a separate mailer.
#
# Both paths are best-effort: any exception is rescued and logged so credit
# transactions are never blocked by a notification failure.
#
# Reasons can be one of: "tip", "bounty", "redemption", "airdrop", "payment",
# "stake_unlock", "tournament_win", "ama_payout", "achievement", "chest",
# "spotlight". Free-form note is appended after a separator.

module DiscourseCoinEngine
  class Notifier
    SYSTEM_BOT_USERNAME = -'system'

    REASON_LABELS = {
      'tip'             => 'Tip received',
      'bounty'          => 'Bounty awarded',
      'bounty_award'    => 'Bounty awarded',
      'redemption'      => 'Shop redemption',
      'airdrop'         => 'Airdrop',
      'payment'         => 'Manual payment',
      'stake_unlock'    => 'Stake unlocked',
      'tournament_win'  => 'Tournament prize',
      'ama_payout'      => 'AMA booking payout',
      'achievement'     => 'Achievement unlocked',
      'chest'           => 'Daily chest claimed',
      'spotlight'       => 'Spotlight reward',
      'manual_payment'  => 'Manual payment',
    }.freeze

    class << self
      # Public API used from controllers.
      #
      #   DiscourseCoinEngine::Notifier.credit!(
      #     recipient: user, amount: 100, reason: 'tip',
      #     sender: current_user, note: 'Thanks for the kitchen reno tips!',
      #     ref: { type: 'tip', id: tip.id, post_id: tip.post_id },
      #   )
      def credit!(recipient:, amount:, reason:, sender: nil, note: nil, ref: nil, send_pm: true)
        return unless recipient && amount && amount.to_i > 0
        publish_message_bus(recipient: recipient, amount: amount, reason: reason, sender: sender, note: note, ref: ref)
        send_private_message(recipient: recipient, amount: amount, reason: reason, sender: sender, note: note, ref: ref) if send_pm
        true
      rescue StandardError => e
        Rails.logger.warn("[coin_engine] Notifier.credit! failed for user_id=#{recipient&.id} reason=#{reason}: #{e.class}: #{e.message}")
        false
      end

      private

      def coin_name
        @coin_name = nil if @coin_name_cached_at.nil? || @coin_name_cached_at < Time.now - 30
        @coin_name_cached_at = Time.now
        @coin_name ||= (SiteSetting.coin_engine_coin_name rescue '$RENO')
      end

      def publish_message_bus(recipient:, amount:, reason:, sender:, note:, ref:)
        new_total = ::DiscourseCoinEngine.coin_user_total(recipient.id)
        payload = {
          amount: amount.to_i,
          reason: reason.to_s,
          label:  REASON_LABELS[reason.to_s] || reason.to_s.tr('_', ' ').capitalize,
          coin:   coin_name,
          new_total: new_total,
          sender: sender ? { id: sender.id, username: sender.username, name: sender.name } : nil,
          note:   note.to_s.presence,
          ref:    ref,
          ts:     Time.now.to_i,
        }
        # User-scoped channel: only this user's clients receive it.
        MessageBus.publish("/coin-engine/credits/#{recipient.id}", payload, user_ids: [recipient.id])
      rescue StandardError => e
        Rails.logger.warn("[coin_engine] Notifier MessageBus publish failed: #{e.class}: #{e.message}")
      end

      def send_private_message(recipient:, amount:, reason:, sender:, note:, ref:)
        bot = ::User.find_by(username_lower: SYSTEM_BOT_USERNAME) || ::Discourse.system_user
        return unless bot
        # Don't PM if the recipient has explicitly silenced PMs from this bot.
        return if bot && respond_to?(:bot_disallowed_for?) && bot_disallowed_for?(recipient)

        coin = coin_name
        label = REASON_LABELS[reason.to_s] || reason.to_s.tr('_', ' ').capitalize
        title = "+#{amount} #{coin} · #{label}"

        sender_line =
          if sender
            "from **@#{sender.username}**"
          else
            'from the community'
          end

        body = +"You just received **+#{amount} #{coin}** #{sender_line}.\n\n"
        body << "**Reason:** #{label}\n\n"
        body << "**Note from sender:**\n> #{note.to_s.gsub(/\s+/, ' ').strip}\n\n" if note.to_s.strip.length > 0

        body << "**Your new balance:** #{::DiscourseCoinEngine.coin_user_total(recipient.id)} #{coin}\n\n"

        if ref.is_a?(Hash) && ref[:post_id]
          body << "[See the post →](/p/#{ref[:post_id]})\n\n"
        end

        body << "---\n"
        body << "[Full payment ledger →](/t/#{SiteSetting.coin_engine_ledger_topic_id})  ·  "
        body << "[Your $RENO profile →](/coin-engine/u/#{recipient.username})  ·  "
        body << "[Manage notifications →](/u/#{recipient.username}/preferences/notifications)\n"

        post_creator = ::PostCreator.new(
          bot,
          title: title,
          raw: body,
          archetype: ::Archetype.private_message,
          target_usernames: recipient.username,
          skip_validations: true,
          skip_jobs: false,         # Fire jobs so email goes out per user prefs.
          custom_fields: { coin_engine_credit: 1, coin_engine_reason: reason.to_s },
        )
        post = post_creator.create
        if post_creator.errors.any?
          Rails.logger.warn("[coin_engine] Notifier PM errors: #{post_creator.errors.full_messages.join(', ')}")
        end
        post
      rescue StandardError => e
        Rails.logger.warn("[coin_engine] Notifier PM creation failed: #{e.class}: #{e.message}")
        nil
      end
    end
  end
end
