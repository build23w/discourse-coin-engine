# frozen_string_literal: true

# v0.19.4 — Admin endpoint to create/list/destroy Tournament records.
#
# The Tournament + TournamentEntry models existed since v0.6.0 (Phase 4)
# along with their tables, but until now there was no admin surface to seed
# tournament rows — the FAB's Tournaments tab queried list_tournaments and
# always rendered "No tournaments live. Stay tuned." because zero rows.
#
# This controller fills that gap. Admin-gated via Discourse's
# Admin::AdminController base class — same auth as every other admin
# tab in the plugin.

module DiscourseCoinEngine
  class AdminTournamentsController < ::Admin::AdminController
    requires_login
    skip_before_action :check_xhr, raise: false

    # GET /admin/coin-engine/tournaments.json
    # List all tournaments regardless of status (admin view).
    def index
      ts = Tournament.order(starts_at: :desc).limit(50)
      render json: {
        tournaments: ts.map { |t| serialize(t) },
      }
    end

    # POST /admin/coin-engine/tournaments.json
    # Body params: slug, name, description, tournament_type, starts_at,
    # ends_at, prize_pool, status (optional, default 'upcoming').
    def create
      attrs = {
        slug:            params[:slug].to_s.strip,
        name:            params[:name].to_s.strip,
        description:     params[:description].to_s,
        tournament_type: params[:tournament_type].to_s.strip,
        starts_at:       parse_time(params[:starts_at]),
        ends_at:         parse_time(params[:ends_at]),
        status:          (params[:status].presence || 'upcoming').to_s,
        prize_pool:      params[:prize_pool].to_i,
      }

      # Light sanity check before hitting the DB so we get nicer 422s
      missing = []
      missing << :slug            if attrs[:slug].empty?
      missing << :name            if attrs[:name].empty?
      missing << :tournament_type if attrs[:tournament_type].empty?
      missing << :starts_at       unless attrs[:starts_at]
      missing << :ends_at         unless attrs[:ends_at]
      if missing.any?
        return render json: { errors: ["missing or invalid: #{missing.join(', ')}"] }, status: 422
      end

      unless %w[upcoming active voting completed].include?(attrs[:status])
        return render json: { errors: ['invalid status'] }, status: 422
      end

      if Tournament.where(slug: attrs[:slug]).exists?
        return render json: { errors: ['slug already taken'] }, status: 409
      end

      t = Tournament.create!(attrs)
      render json: { tournament: serialize(t) }, status: 201
    rescue ActiveRecord::RecordInvalid => e
      render json: { errors: e.record.errors.full_messages }, status: 422
    rescue StandardError => e
      Rails.logger.warn "[coin-engine] admin tournament create failed: #{e.class}: #{e.message}"
      render json: { errors: ["#{e.class}: #{e.message[0,200]}"] }, status: 500
    end

    # DELETE /admin/coin-engine/tournaments/:slug.json
    def destroy
      t = Tournament.find_by(slug: params[:slug])
      return render json: { errors: ['not found'] }, status: 404 unless t
      TournamentEntry.where(tournament_id: t.id).delete_all
      t.destroy!
      render json: { ok: true }
    end

    private

    def parse_time(raw)
      return nil if raw.blank?
      Time.parse(raw.to_s)
    rescue ArgumentError
      nil
    end

    def serialize(t)
      {
        id:              t.id,
        slug:            t.slug,
        name:            t.name,
        description:     t.description,
        tournament_type: t.tournament_type,
        starts_at:       t.starts_at,
        ends_at:         t.ends_at,
        status:          t.status,
        prize_pool:      t.prize_pool,
        winner_user_id:  t.winner_user_id,
        winning_topic_id: t.winning_topic_id,
      }
    end
  end
end
