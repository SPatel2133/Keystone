require "bigdecimal"
require "time"
require_relative "payments"
require_relative "storage"

module ShopifyLedger
  # Explains totals: every stored payment transaction with the delivery or
  # reconciliation run that first recorded it, and for one order, the webhook
  # deliveries that referenced it. Read-only, in one SQLite read transaction.
  class Audit
    DEFAULT_LIMIT = 500

    def initialize(config)
      @storage = Storage.new(config.database)
    end

    def report(shop, order_id: nil, limit: DEFAULT_LIMIT)
      @storage.connect do |db|
        db.transaction(:deferred)
        begin
          order_id ? order(db, shop, order_id) : shop_report(db, shop, limit)
        ensure
          db.rollback if db.transaction_active?
        end
      end
    end

    private

    COLUMNS = "transaction_id, order_id, kind, currency, amount, source, recorded_at"

    def shop_report(db, shop, limit)
      rows = db.execute(<<~SQL, [shop, limit + 1])
        SELECT #{COLUMNS} FROM transactions WHERE shop = ?
        ORDER BY recorded_at IS NOT NULL, recorded_at, order_id, transaction_id LIMIT ?
      SQL
      {
        shop: shop, totals: Payments.summary(db, shop),
        transaction_count: db.get_first_value("SELECT COUNT(*) FROM transactions WHERE shop = ?", [shop]),
        truncated: rows.size > limit, transactions: rows.first(limit).map { |row| describe(row) }
      }
    end

    def order(db, shop, order_id)
      rows = db.execute(<<~SQL, [shop, order_id])
        SELECT #{COLUMNS} FROM transactions WHERE shop = ? AND order_id = ?
        ORDER BY recorded_at IS NOT NULL, recorded_at, transaction_id
      SQL
      deliveries = db.execute(<<~SQL, [shop, order_id])
        SELECT webhook_id, topic, processed, parked_at, attempts, requeues, received_at, processed_at, last_error
        FROM inbox WHERE shop = ? AND order_id = ? ORDER BY id
      SQL
      {
        shop: shop, order_id: order_id, totals: totals(rows),
        transactions: rows.map { |row| describe(row) },
        deliveries: deliveries.map do |webhook_id, topic, processed, parked_at, attempts, requeues, received, done, error|
          state = if processed == 1 then "processed" elsif parked_at then "parked" elsif attempts.positive? then "failing" else "pending" end
          { webhook_id: webhook_id, topic: topic, state: state, attempts: attempts, requeues: requeues,
            received_at: iso(received), processed_at: iso(done), last_error: error }
        end
      }
    end

    def totals(rows)
      rows.group_by { |row| row[3] }.sort.map do |currency, entries|
        collected, refunded = %w[SALE REFUND].map do |side|
          entries.select { |row| (row[2] == "REFUND") == (side == "REFUND") }.sum(BigDecimal("0")) { |row| BigDecimal(row[4]) }
        end
        { currency: currency, collected: Payments.format_decimal(collected),
          refunded: Payments.format_decimal(refunded), net: Payments.format_decimal(collected - refunded) }
      end
    end

    def describe(row)
      transaction_id, order_id, kind, currency, amount, source, recorded_at = row
      origin, reference = source&.split(":", 2)
      { transaction_id: transaction_id, order_id: order_id, kind: kind, currency: currency, amount: amount,
        recorded_by: origin || "unknown", reference: reference, recorded_at: iso(recorded_at) }
    end

    def iso(seconds)
      seconds&.positive? ? Time.at(seconds).utc.iso8601 : nil
    end
  end
end
