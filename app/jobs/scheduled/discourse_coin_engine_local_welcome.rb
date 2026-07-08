# frozen_string_literal: true

module Jobs
  # v0.35.0 - Local onboarding PM. New members get a personal note from the
  # site contact naming the most active threads near them (when they have a
  # location) or pointing at the location quest (when they don't). One PM per
  # user ever, guarded by a user_custom_field; daily send cap for safety.
  class DiscourseCoinEngineLocalWelcome < ::Jobs::Scheduled
    every 1.day

    FIELD = 'coin_engine_local_welcome_sent'

    def execute(args)
      return unless SiteSetting.coin_engine_enabled
      return unless SiteSetting.coin_engine_local_welcome_enabled

      cap = SiteSetting.coin_engine_local_welcome_daily_cap.to_i.clamp(1, 200)
      sender = resolve_sender
      return if sender.nil?

      sent = 0
      welcomed_ids = ::UserCustomField.where(name: FIELD).select(:user_id)
      ::User.real.activated
            .where(staged: false, suspended_till: nil, silenced_till: nil)
            .where('users.created_at >= ?', 3.days.ago)
            .where.not(id: welcomed_ids)
            .order(:created_at)
            .find_each do |user|
        break if sent >= cap
        begin
          send_welcome(sender, user)
          mark_sent(user.id)
          sent += 1
        rescue StandardError => e
          Rails.logger.warn "[coin-engine] local welcome failed for #{user.username}: #{e.message}"
        end
      end
    end

    private

    def resolve_sender
      name = SiteSetting.site_contact_username.to_s.strip
      (name.present? && ::User.find_by(username_lower: name.downcase)) || ::Discourse.system_user
    end

    def send_welcome(sender, user)
      coin = SiteSetting.coin_engine_coin_name
      city = ::DiscourseCoinEngine::GeoDigest.label_for(user)
      body = +"Welcome to #{SiteSetting.title}, @#{user.username}!\n\n"

      if city.present?
        rows = ::DiscourseCoinEngine::GeoDigest.topics_for_location(
          ::DiscourseCoinEngine::GeoDigest.location_of(user), limit: 3, since: 30.days.ago
        )
        if rows.present?
          body << "Since you're near **#{city}**, here's what your neighbours are talking about right now:\n\n"
          rows.each { |id, t, slug, *_| body << "- [#{t}](/t/#{slug}/#{id})\n" }
          body << "\n"
        end
        if (lw = ::DiscourseCoinEngine::GeoDigest.local_weekly_path(user))
          body << "The weekly [#{city} roundup](#{lw}) collects the best local threads - worth a bookmark.\n\n"
        end
      else
        body << "Tip: [set your location](/my/preferences/profile) and your feed, digests and "
        body << "recommendations all go local to you"
        body << (SiteSetting.coin_engine_location_quest_enabled ? " - it also completes a quest that pays #{coin}.\n\n" : ".\n\n")
      end

      body << "Every helpful post here earns #{coin} - [how it works](/t/#{SiteSetting.coin_engine_welcome_topic_id}).\n\n"
      body << "Got a reno question? Just start a topic - this community answers fast."

      title = city.present? ? "Welcome - your #{city} starter kit" : "Welcome to #{SiteSetting.title}"
      creator = ::PostCreator.new(
        sender,
        title: title,
        raw: body,
        archetype: ::Archetype.private_message,
        target_usernames: user.username,
        skip_validations: true,
      )
      creator.create
      raise creator.errors.full_messages.join(', ') if creator.errors.any?
    end

    def mark_sent(user_id)
      # user_custom_fields has NO unique index - delete-then-insert.
      ::UserCustomField.where(user_id: user_id, name: FIELD).delete_all
      ::UserCustomField.create!(user_id: user_id, name: FIELD, value: Date.today.to_s)
    end
  end
end
