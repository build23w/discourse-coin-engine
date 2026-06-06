# frozen_string_literal: true

# v0.32.0 — Squad HQ. When an enabled squad reaches the member threshold it gets:
#   1. A mirror Discourse group ("squad-<slug>") kept in sync on join/leave.
#   2. Its own subcategory under the configured "Squads" parent category —
#      public read (everyone sees squad activity, good for SEO + recruitment),
#      posting restricted to squad members via the mirror group.
# All entry points are best-effort: failures log and never block squad actions.
module DiscourseCoinEngine
  module SquadHq
    def self.enabled?
      SiteSetting.coin_engine_squad_hq_enabled &&
        SiteSetting.coin_engine_squad_hq_parent_category_id.to_i > 0
    rescue StandardError
      false
    end

    def self.group_name(squad)
      "squad-#{squad.slug}"[0, 60]
    end

    # Idempotent: creates group + subcategory once eligibility is met.
    def self.ensure_hq!(squad)
      return unless enabled?
      return unless squad && squad.enabled
      return if squad.category_id.to_i > 0
      member_count = SquadMembership.where(squad_id: squad.id).count
      return if member_count < [SiteSetting.coin_engine_squad_hq_min_members.to_i, 1].max
      parent = ::Category.find_by(id: SiteSetting.coin_engine_squad_hq_parent_category_id.to_i)
      return unless parent

      group = ensure_group!(squad)
      return unless group

      name = squad.name.to_s.strip[0, 50]
      name = "#{name} (#{squad.slug})"[0, 50] if ::Category.where(parent_category_id: parent.id, name: name).exists?
      cat = ::Category.new(
        name: name,
        user: ::Discourse.system_user,
        parent_category_id: parent.id,
        description: (squad.description.presence || "Home base for the #{squad.name} squad — members coordinate projects, share wins, and recruit here."),
        color: (squad.color.presence || '7C4DFF').to_s.delete('#')[0, 6],
        text_color: 'FFFFFF'
      )
      cat.set_permissions(everyone: :readonly, group.name => :full)
      cat.save!
      squad.update_columns(category_id: cat.id)
      Rails.logger.info("[coin-engine] SquadHq created category=#{cat.id} group=#{group.id} for squad=#{squad.slug}")
      cat
    rescue StandardError => e
      Rails.logger.warn("[coin-engine] SquadHq.ensure_hq! failed squad=#{squad&.id}: #{e.class}: #{e.message}")
      nil
    end

    def self.ensure_group!(squad)
      if squad.group_id.to_i > 0
        g = ::Group.find_by(id: squad.group_id)
        return g if g
      end
      gname = group_name(squad)
      g = ::Group.find_by(name: gname)
      g ||= ::Group.create!(
        name: gname,
        full_name: "#{squad.name} Squad"[0, 100],
        visibility_level: ::Group.visibility_levels[:public],
        public_exit: false, public_admission: false
      )
      # Backfill current members so permissions are correct from minute one.
      uids = SquadMembership.where(squad_id: squad.id).pluck(:user_id)
      ::User.where(id: uids).find_each do |u|
        begin g.add(u) rescue StandardError; end
      end
      squad.update_columns(group_id: g.id)
      g
    rescue StandardError => e
      Rails.logger.warn("[coin-engine] SquadHq.ensure_group! failed squad=#{squad&.id}: #{e.class}: #{e.message}")
      nil
    end

    def self.sync_member!(squad, user, op)
      return unless squad && user
      return unless squad.group_id.to_i > 0
      g = ::Group.find_by(id: squad.group_id)
      return unless g
      op.to_sym == :remove ? g.remove(user) : g.add(user)
    rescue StandardError => e
      Rails.logger.warn("[coin-engine] SquadHq.sync_member! failed squad=#{squad&.id} user=#{user&.id}: #{e.class}: #{e.message}")
    end
  end
end
