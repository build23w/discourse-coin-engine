# frozen_string_literal: true

# v0.24.0 — Admin CRUD for regional squads (JSON API). Lets staff create,
# rename, recolor, enable/disable and delete squads without a rails console.
# Squad scores/member counts are maintained automatically by the
# DiscourseCoinEngineRefreshSquadScores scheduled job.
module DiscourseCoinEngine
  class AdminSocialController < ::Admin::AdminController
    requires_login
    skip_before_action :check_xhr, raise: false

    # GET /admin/coin-engine/social/squads.json
    def squads_index
      render json: { squads: Squad.order(total_score: :desc).map { |s| serialize(s) } }
    end

    # POST /admin/coin-engine/social/squads.json
    def squads_create
      s = Squad.create!(
        slug:        normalize_slug(params[:slug].presence || params[:name]),
        name:        params[:name].to_s.strip[0, 120],
        region:      params[:region].to_s.strip[0, 60].presence,
        icon:        params[:icon].to_s.strip[0, 16].presence,
        color:       params[:color].to_s.strip[0, 16].presence,
        description: params[:description].to_s.strip[0, 500].presence,
        enabled:     bool_param(:enabled, true),
        member_count: 0,
        total_score:  0,
      )
      render json: { squad: serialize(s) }
    rescue ActiveRecord::RecordInvalid => e
      render json: { errors: e.record.errors.full_messages }, status: 422
    rescue ActiveRecord::RecordNotUnique
      render json: { errors: ['A squad with that slug already exists'] }, status: 422
    end

    # PUT /admin/coin-engine/social/squads/:id.json
    def squads_update
      s = Squad.find_by(id: params[:id])
      return render json: { errors: ['squad not found'] }, status: 404 unless s
      %i[name region icon color description].each do |k|
        s.public_send("#{k}=", params[k].to_s.strip) if params.key?(k)
      end
      s.enabled = bool_param(:enabled, s.enabled) if params.key?(:enabled)
      s.save!
      render json: { squad: serialize(s) }
    rescue ActiveRecord::RecordInvalid => e
      render json: { errors: e.record.errors.full_messages }, status: 422
    end

    # DELETE /admin/coin-engine/social/squads/:id.json
    def squads_destroy
      s = Squad.find_by(id: params[:id])
      return render json: { errors: ['squad not found'] }, status: 404 unless s
      SquadMembership.where(squad_id: s.id).delete_all
      s.destroy
      render json: { ok: true }
    end

    private

    def normalize_slug(raw)
      raw.to_s.strip.downcase.gsub(/[^a-z0-9]+/, '-').gsub(/\A-+|-+\z/, '')[0, 60]
    end

    def bool_param(key, default)
      return default unless params.key?(key)
      ::ActiveModel::Type::Boolean.new.cast(params[key])
    end

    def serialize(s)
      { id: s.id, slug: s.slug, name: s.name, region: s.region, icon: s.icon, color: s.color,
        description: s.description, member_count: s.member_count, total_score: s.total_score, enabled: s.enabled }
    end
  end
end
