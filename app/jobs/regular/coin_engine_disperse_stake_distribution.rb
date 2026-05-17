# frozen_string_literal: true

# v0.21.0 — Background job: snapshot active stakers and create payout rows
# for a pending coin_engine_stake_distributions row.
#
# Triggered by AdminStakeDistributionsController#create. Idempotent: re-running
# for the same distribution_id is a no-op once status has moved past 'pending'.
#
# Pro-rata math:
#   For each active staker S with locked lamports L_s, where total locked is L_total:
#     payout_S = floor(distribution.total_amount * L_s / L_total)
#
#   Floor division can leave a small residual unclaimed (≤ stakers_count $RENO).
#   That residual stays in the reserve — we don't reallocate to avoid uneven
#   re-rounding effects. The cumulative residual across many distributions is
#   negligible relative to typical payout amounts.

module ::Jobs
  class CoinEngineDisperseStakeDistribution < ::Jobs::Base
    def execute(args)
      distribution_id = args[:distribution_id].to_i
      return if distribution_id <= 0

      d = ::DiscourseCoinEngine::StakeDistribution.find_by(id: distribution_id)
      return unless d

      # Idempotency guard — only run if still pending.
      unless d.status == 'pending'
        Rails.logger.info("[coin-engine] stake distribution #{distribution_id} already in status '#{d.status}', skipping job")
        return
      end

      d.update!(status: 'computed', started_at: Time.zone.now)

      begin
        ActiveRecord::Base.transaction do
          # Snapshot active SOL stakes. Aggregate per-user in case one user
          # has multiple active stakes (which is legal in the plugin).
          rows = ::ActiveRecord::Base.connection.exec_query(<<~SQL).to_a
            SELECT user_id, SUM(amount_lamports)::bigint AS lamports
            FROM coin_engine_sol_stakes
            WHERE status = 'active'
              AND user_id > 0
            GROUP BY user_id
            HAVING SUM(amount_lamports) > 0
            ORDER BY lamports DESC
          SQL

          total_lamports = rows.sum { |r| r["lamports"].to_i }
          stakers_count  = rows.size

          if stakers_count == 0 || total_lamports == 0
            d.update!(
              status:               'completed',
              completed_at:         Time.zone.now,
              stakers_count:        0,
              total_stake_lamports: 0,
              notes:                [d.notes.to_s, "No active stakers at snapshot — nothing to distribute."].reject(&:empty?).join("\n"),
            )
            Rails.logger.info("[coin-engine] stake distribution #{distribution_id}: no active stakers, marked completed")
            return
          end

          total_amount = d.total_amount.to_i
          allocated   = 0
          payout_rows = []

          rows.each do |r|
            uid       = r["user_id"].to_i
            lamports  = r["lamports"].to_i
            share     = (total_amount.to_i * lamports) / total_lamports # integer floor
            allocated += share
            payout_rows << {
              distribution_id:                   d.id,
              user_id:                           uid,
              stake_amount_lamports_at_snapshot: lamports,
              payout_amount:                     share,
              status:                            'pending',
              created_at:                        Time.zone.now,
              updated_at:                        Time.zone.now,
            }
          end

          # Bulk insert all payout rows in one statement.
          ::DiscourseCoinEngine::StakePayout.insert_all!(payout_rows)

          residual = total_amount - allocated
          notes_extra = "Allocated #{allocated} of #{total_amount} $RENO across #{stakers_count} stakers. " \
                        "Floor-division residual: #{residual} $RENO (retained in reserve)."

          d.update!(
            status:               'completed',
            completed_at:         Time.zone.now,
            stakers_count:        stakers_count,
            total_stake_lamports: total_lamports,
            notes:                [d.notes.to_s, notes_extra].reject(&:empty?).join("\n"),
          )

          Rails.logger.info("[coin-engine] stake distribution #{distribution_id}: #{stakers_count} stakers, #{allocated}/#{total_amount} $RENO allocated, residual #{residual}")
        end
      rescue StandardError => e
        Rails.logger.error("[coin-engine] stake distribution #{distribution_id} dispersal FAILED: #{e.class}: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}")
        begin
          d.update!(status: 'failed', notes: [d.notes.to_s, "DISPERSE FAILED: #{e.class}: #{e.message[0,300]}"].reject(&:empty?).join("\n"))
        rescue StandardError
          nil
        end
      end
    end
  end
end
