# frozen_string_literal: true

# v0.12.0 - Admin CRUD for store items.

module DiscourseCoinEngine
  class AdminStoreController < ::Admin::AdminController
    requires_login
    before_action :ensure_admin

    rescue_from ActiveRecord::RecordInvalid do |e|
      render json: { errors: e.record.errors.full_messages }, status: 422
    end

    rescue_from ::Discourse::InvalidParameters do |e|
      render json: { errors: [e.message] }, status: 400
    end

    def index
      scope = StoreItem.order(featured: :desc, position: :asc, id: :asc)
      scope = scope.where(active: ActiveModel::Type::Boolean.new.cast(params[:active])) if params.key?(:active)
      scope = scope.where(kind: params[:kind]) if StoreItem::KINDS.include?(params[:kind].to_s)
      render json: { items: scope.limit(200).map { |i| serialize_admin(i) } }
    end

    def stats
      render json: {
        active:       StoreItem.active.count,
        total:        StoreItem.count,
        sold_count:   StorePurchase.where(status: %w[paid fulfilled]).count,
        gross_reno:   StorePurchase.where(currency: 'reno', status: %w[paid fulfilled]).sum(:amount_paid),
        gross_lamps:  StorePurchase.where(currency: 'sol',  status: %w[paid fulfilled]).sum(:amount_paid),
      }
    end

    def create
      attrs = item_params
      attrs[:created_by_user_id] = current_user.id
      attrs[:slug] = generate_slug(attrs[:name]) if attrs[:slug].blank? && attrs[:name].present?
      item = StoreItem.create!(attrs)
      render json: { item: serialize_admin(item) }
    end

    def update
      item = StoreItem.find_by(id: params[:id])
      raise ::Discourse::NotFound unless item
      item.update!(item_params)
      render json: { item: serialize_admin(item) }
    end

    def destroy
      item = StoreItem.find_by(id: params[:id])
      raise ::Discourse::NotFound unless item
      # Soft delete: just mark inactive. Real delete is risky if there are purchases.
      item.update!(active: false)
      render json: { ok: true }
    end

    def reorder
      ids = (params[:order] || []).map(&:to_i)
      ids.each_with_index do |id, idx|
        StoreItem.where(id: id).update_all(position: idx, updated_at: Time.zone.now)
      end
      render json: { ok: true }
    end

    def purchases
      page  = [params[:page].to_i, 1].max
      per   = 25
      scope = StorePurchase.recent.includes(:user, :item).limit(per).offset((page - 1) * per)
      scope = scope.where(status: params[:status]) if StorePurchase::STATUSES.include?(params[:status].to_s)
      total = StorePurchase.count
      render json: {
        purchases: scope.map { |p| serialize_admin_purchase(p) },
        page:      page,
        per_page:  per,
        total:     total,
      }
    end

    def fulfill
      pp = StorePurchase.find_by(id: params[:id])
      raise ::Discourse::NotFound unless pp
      pp.update!(status: 'fulfilled', fulfilled_at: Time.zone.now)
      render json: { ok: true, purchase: serialize_admin_purchase(pp) }
    end

    def refund
      pp = StorePurchase.find_by(id: params[:id])
      raise ::Discourse::NotFound unless pp
      return render json: { errors: ['Already refunded.'] }, status: 422 if pp.status == 'refunded'

      ::ActiveRecord::Base.transaction do
        pp.update!(status: 'refunded')
        # If they paid in $RENO, credit it back
        if pp.currency == 'reno' && pp.amount_paid.to_i > 0
          ::DiscourseCoinEngine.credit_score(pp.user_id, Date.today, pp.amount_paid.to_i)
        end
        # Restore the supply slot if there is one
        if pp.item_id
          ::DiscourseCoinEngine::StoreItem.where(id: pp.item_id).where('sold_count > 0')
            .update_all('sold_count = sold_count - 1, updated_at = NOW()')
        end
      end
      render json: { ok: true, purchase: serialize_admin_purchase(pp) }
    end

    private

    def item_params
      p = params.permit(
        :kind, :name, :slug, :description, :image_url, :mint_address,
        :price_reno, :price_sol_lamports, :supply, :position,
        :active, :featured, :traits_json, :released_at, :expires_at,
      )
      p[:price_reno]         = p[:price_reno].to_i         if p.key?(:price_reno)
      p[:price_sol_lamports] = p[:price_sol_lamports].to_i if p.key?(:price_sol_lamports)
      p[:supply]             = p[:supply].to_i             if p.key?(:supply)
      p[:position]           = p[:position].to_i           if p.key?(:position)
      p
    end

    def generate_slug(name)
      base = name.to_s.downcase.gsub(/[^a-z0-9]+/, '-').gsub(/^-+|-+$/, '')[0, 100]
      slug = base
      n = 1
      while StoreItem.exists?(slug: slug)
        n += 1
        slug = "#{base}-#{n}"
      end
      slug
    end

    def serialize_admin(item)
      item.serialize_for_user.merge(
        active:           item.active,
        position:         item.position,
        created_by:       item.created_by_user_id,
        created_at:       item.created_at,
        updated_at:       item.updated_at,
      )
    end

    def serialize_admin_purchase(pp)
      pp.serialize_for_user.merge(
        user:  pp.user ? { id: pp.user.id, username: pp.user.username } : nil,
        item:  pp.item ? { id: pp.item.id, name: pp.item.name, slug: pp.item.slug } : nil,
      )
    end
  end
end
