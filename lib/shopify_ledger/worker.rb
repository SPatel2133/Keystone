require "time"
require_relative "admin"
require_relative "log"
require_relative "payments"
require_relative "storage"

module ShopifyLedger
  class Worker
    def initialize(config)
      @config = config
      @storage = Storage.new(config.database)
    end

    def run_once(before_commit: nil, after_commit: nil)
      loop do
        delivery = next_delivery
        return "idle" unless delivery

        result = process(delivery, before_commit, after_commit)
        return result if result
      end
    rescue SQLite3::Exception => error
      Log.event("worker_storage_error", error: "#{error.class}: #{error.message}")
      "retry"
    end

    def self.delay(attempts)
      [2**([attempts, 5].min + 1), 60].min
    end

    private

    def next_delivery
      @storage.connect do |db|
        db.get_first_row(<<~SQL, [Time.now.to_i])
          SELECT id, shop, order_id, attempts, webhook_id FROM inbox INDEXED BY inbox_eligible
          WHERE processed = 0 AND parked_at IS NULL AND next_attempt_at <= ?
          ORDER BY id LIMIT 1
        SQL
      end
    end

    def process(delivery, before_commit, after_commit)
      id, shop, order_id, attempts, webhook_id = delivery
      raise Admin::Error, "Delivery shop is no longer configured" unless @config.shop?(shop)

      transactions = Admin.new(@config, shop).order_transactions(order_id)
      entries = Payments.entries(transactions)

      applied = false
      recorded = 0
      result = @storage.connect do |db|
        # Another worker may have finished while this one was fetching.
        Storage.transaction(
          db,
          before_commit: -> { before_commit&.call if applied },
          after_commit: -> { after_commit&.call if applied }
        ) do
          pending = db.get_first_value("SELECT 1 FROM inbox WHERE id = ? AND processed = 0 AND parked_at IS NULL", [id])
          # Reselect if a different worker already committed or an operator parked this delivery.
          next unless pending

          recorded = Payments.apply(db, shop, order_id, entries, source: "delivery:#{webhook_id}")
          now = Time.now.to_i
          db.execute(<<~SQL, [now, now, id])
            UPDATE inbox SET processed = 1, next_attempt_at = 0, last_error = NULL,
                             last_attempt_at = ?, processed_at = ?
            WHERE id = ?
          SQL
          applied = true
          "processed"
        end
      end
      if result
        Log.event("delivery_processed", shop: shop, delivery: webhook_id, order: order_id,
                                        attempt: attempts + 1, recorded_transactions: recorded)
      end
      result
    rescue Admin::Error, Payments::Error, SQLite3::Exception => error
      outcome = record_retry(delivery, error)
      return unless outcome

      Log.event("delivery_#{outcome}", shop: shop, delivery: webhook_id, order: order_id,
                                       attempt: attempts + 1, error: "#{error.class}: #{error.message}")
      outcome
    end

    # Returns "retry" or "parked", or nil when another worker changed the row first.
    def record_retry(delivery, error)
      id, _shop, _order_id, attempts = delivery
      now = Time.now.to_i
      parked = attempts + 1 >= @config.max_attempts
      @storage.connect do |db|
        Storage.transaction(db) do
          db.execute(<<~SQL, [now + self.class.delay(attempts), error.message, now, parked ? now : nil, id, attempts])
            UPDATE inbox SET attempts = attempts + 1, next_attempt_at = ?, last_error = ?,
                             last_attempt_at = ?, parked_at = ?
            WHERE id = ? AND processed = 0 AND parked_at IS NULL AND attempts = ?
          SQL
          db.changes == 1 ? (parked ? "parked" : "retry") : nil
        end
      end
    rescue SQLite3::Exception => storage_error
      Log.event("delivery_retry_unrecorded", error: "#{storage_error.class}: #{storage_error.message}")
      "retry"
    end
  end
end
