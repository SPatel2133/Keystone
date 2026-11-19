module ShopifyLedger
  module Postgres
    class Worker
      LEASE = 60

      def initialize(config, db, owner: "#{Socket.gethostname}:#{Process.pid}")
        @config = config
        @db = db
        @owner = owner
      end

      def drain
        counts = { "processed" => 0, "retry" => 0, "parked" => 0 }
        loop do
          outcome = run_once
          return counts.merge("status" => "idle") if outcome == "idle"

          counts[outcome] += 1
        end
      end

      def run_once(before_commit: nil, after_commit: nil)
        claim = claim_next or return "idle"
        id, shop, order_id, attempts, webhook_id = claim
        fence = @db.get_first_value("SELECT MAX(id) FROM inbox WHERE shop = ? AND order_id = ?", [shop, order_id])
        raise Admin::Error, "Delivery shop is no longer configured" unless @config.shop?(shop)

        entries = Payments.entries(Admin.new(@config, shop).order_transactions(order_id))
        applied = @db.transaction do |db|
          # Lock every same-order row this completion may touch, in id order, so
          # concurrent completions of one order queue instead of deadlocking.
          db.execute("SELECT id FROM inbox WHERE shop = ? AND order_id = ? AND id <= ? ORDER BY id FOR UPDATE",
                     [shop, order_id, fence])
          next false unless db.get_first_value("SELECT processed FROM inbox WHERE id = ?", [id]) == 0

          Payments.apply(db, shop, order_id, entries, source: "delivery:#{webhook_id}")
          now = Time.now.to_i
          db.execute(<<~SQL, [now, now, shop, order_id, fence])
            UPDATE inbox SET processed = 1, processed_at = ?, last_attempt_at = ?, last_error = NULL,
                             claimed_by = NULL, claimed_until = NULL
            WHERE shop = ? AND order_id = ? AND processed = 0 AND parked_at IS NULL AND id <= ?
          SQL
          before_commit&.call
          true
        end
        after_commit&.call if applied
        "processed"
      rescue Admin::Error, Payments::Error => error
        defer(id, attempts, error)
      end

      private

      def claim_next
        now = Time.now.to_i
        @db.get_first_row(<<~SQL, [@owner, now + LEASE, now, now])
          UPDATE inbox SET claimed_by = ?, claimed_until = ?
          WHERE id = (
            SELECT id FROM inbox
            WHERE processed = 0 AND parked_at IS NULL AND next_attempt_at <= ?
              AND (claimed_until IS NULL OR claimed_until <= ?)
            ORDER BY id LIMIT 1
            FOR UPDATE SKIP LOCKED
          )
          RETURNING id, shop, order_id, attempts, webhook_id
        SQL
      end

      def defer(id, attempts, error)
        now = Time.now.to_i
        parked = attempts + 1 >= @config.max_attempts
        @db.execute(<<~SQL, [error.message, now + [2**(attempts + 1), 60].min, parked ? now : nil, now, id])
          UPDATE inbox SET attempts = attempts + 1, last_error = ?, next_attempt_at = ?, parked_at = ?,
                           last_attempt_at = ?, claimed_by = NULL, claimed_until = NULL
          WHERE id = ? AND processed = 0
        SQL
        Log.event(parked ? "delivery_parked" : "delivery_retry", delivery: id, error: "#{error.class}: #{error.message}")
        parked ? "parked" : "retry"
      end
    end
  end
end
