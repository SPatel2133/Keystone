require_relative "storage"

module ShopifyLedger
  # Read-only inspection of webhook deliveries plus one targeted recovery action.
  class Deliveries
    STATES = {
      "pending" => "processed = 0 AND parked_at IS NULL",
      "failing" => "processed = 0 AND parked_at IS NULL AND attempts > 0",
      "parked" => "processed = 0 AND parked_at IS NOT NULL",
      "processed" => "processed = 1",
      "all" => "1 = 1"
    }.freeze
    LIMIT = 100

    class Refused < StandardError; end

    def initialize(config, store: nil)
      @config = config
      @store = store
    end

    def list(shop, state, limit: LIMIT)
      condition = STATES.fetch(state) { raise ArgumentError, "state must be one of #{STATES.keys.join(', ')}" }
      store(shop).connect do |db|
        db.execute(<<~SQL, [shop, limit]).map { |row| describe(row) }
          SELECT #{COLUMNS} FROM inbox WHERE shop = ? AND #{condition} ORDER BY id LIMIT ?
        SQL
      end
    end

    # Makes one parked or backing-off delivery immediately eligible with a fresh
    # attempt budget. Processed deliveries are refused: their effects are final.
    def retry(shop, webhook_id)
      store = store(shop)
      store.connect do |db|
        store.transaction(db) do
          row = db.get_first_row("SELECT #{COLUMNS} FROM inbox WHERE shop = ? AND webhook_id = ?", [shop, webhook_id])
          raise Refused, "delivery not found" unless row
          raise Refused, "delivery already processed" if row[4] == 1

          db.execute(<<~SQL, [shop, webhook_id])
            UPDATE inbox SET attempts = 0, next_attempt_at = 0, parked_at = NULL, requeues = requeues + 1
            WHERE shop = ? AND webhook_id = ? AND processed = 0
          SQL
          describe(db.get_first_row("SELECT #{COLUMNS} FROM inbox WHERE shop = ? AND webhook_id = ?", [shop, webhook_id]))
        end
      end
    end

    COLUMNS = "webhook_id, topic, order_id, attempts, processed, parked_at, next_attempt_at, " \
              "received_at, last_attempt_at, processed_at, requeues, last_error"

    private

    def store(shop) = @store || Storage::Store.new(@config.database_for(shop))

    def describe(row)
      webhook_id, topic, order_id, attempts, processed, parked_at, next_attempt_at,
        received_at, last_attempt_at, processed_at, requeues, last_error = row
      state = if processed == 1 then "processed"
              elsif parked_at then "parked"
              elsif attempts.positive? then "failing"
              else "pending"
              end
      {
        webhook_id: webhook_id, topic: topic, order_id: order_id, state: state,
        attempts: attempts, requeues: requeues, last_error: last_error,
        received_at: iso(received_at), last_attempt_at: iso(last_attempt_at),
        next_attempt_at: state.start_with?("p") ? nil : iso(next_attempt_at),
        parked_at: iso(parked_at), processed_at: iso(processed_at)
      }
    end

    def iso(seconds)
      seconds&.positive? ? Time.at(seconds).utc.iso8601 : nil
    end
  end
end
