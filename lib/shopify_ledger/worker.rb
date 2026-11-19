require_relative "admin"
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
      warn "shopify worker: #{error.class}: #{error.message}"
      "retry"
    end

    private

    def next_delivery
      @storage.connect do |db|
        db.get_first_row(<<~SQL, [Time.now.to_i])
          SELECT id, shop, order_id, attempts FROM inbox
          WHERE processed = 0 AND next_attempt_at <= ?
          ORDER BY id LIMIT 1
        SQL
      end
    end

    def process(delivery, before_commit, after_commit)
      id, shop, order_id = delivery
      raise Admin::Error, "Delivery shop is no longer configured" unless @config.shop?(shop)

      transactions = Admin.new(@config, shop).order_transactions(order_id)
      entries = Payments.entries(transactions)

      applied = false
      @storage.connect do |db|
        # Another worker may have finished while this one was fetching.
        Storage.transaction(
          db,
          before_commit: -> { before_commit&.call if applied },
          after_commit: -> { after_commit&.call if applied }
        ) do
          pending = db.get_first_value("SELECT 1 FROM inbox WHERE id = ? AND processed = 0", [id])
          # Reselect if a different worker already committed this delivery.
          next unless pending

          Payments.apply(db, shop, order_id, entries)
          db.execute(<<~SQL, [id])
            UPDATE inbox SET processed = 1, next_attempt_at = 0, last_error = NULL
            WHERE id = ?
          SQL
          applied = true
          "processed"
        end
      end
    rescue Admin::Error, Payments::Error, SQLite3::Exception => error
      return unless record_retry(delivery, error)

      warn "shopify worker: #{error.class}: #{error.message}"
      "retry"
    end

    def record_retry(delivery, error)
      id, _shop, _order_id, attempts = delivery
      delay = [2**([attempts, 5].min + 1), 60].min
      @storage.connect do |db|
        Storage.transaction(db) do
          db.execute(<<~SQL, [Time.now.to_i + delay, error.message, id, attempts])
            UPDATE inbox SET attempts = attempts + 1, next_attempt_at = ?, last_error = ?
            WHERE id = ? AND processed = 0 AND attempts = ?
          SQL
          db.changes == 1
        end
      end
    rescue SQLite3::Exception => storage_error
      warn "shopify worker could not schedule retry: #{storage_error.class}: #{storage_error.message}"
      true
    end
  end
end
