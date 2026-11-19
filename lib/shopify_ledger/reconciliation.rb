require "time"
require "set"
require_relative "admin"
require_relative "payments"
require_relative "storage"

module ShopifyLedger
  class Reconciliation
    FIRST_LOOKBACK = 7 * 24 * 60 * 60
    OVERLAP = 5 * 60

    def initialize(config, clock: -> { Time.now })
      @config = config
      @storage = Storage.new(config.database)
      @clock = clock
    end

    def run(shop)
      upper = @clock.call.getutc
      admin = Admin.new(@config, shop)
      lower = @storage.connect do |db|
        Storage.transaction(db) do
          checkpoint = read_checkpoint(db, shop)
          return checkpoint if checkpoint && Time.iso8601(checkpoint) > upper

          if checkpoint
            Time.iso8601(checkpoint) - OVERLAP
          else
            # A failed first scan has no completed checkpoint. Persist its
            # start before fetching so an order cannot age out between retries.
            db.execute(<<~SQL, [shop, (upper - FIRST_LOOKBACK).iso8601])
              INSERT INTO reconciliation_starts (shop, window_start) VALUES (?, ?)
              ON CONFLICT (shop) DO NOTHING
            SQL
            Time.iso8601(db.get_first_value("SELECT window_start FROM reconciliation_starts WHERE shop = ?", [shop]))
          end
        end
      end
      filter = "updated_at:>='#{lower.utc.iso8601}' updated_at:<='#{upper.iso8601}'"
      reconcile_orders(admin, shop, filter)
      advance_checkpoint(shop, upper.iso8601)
    end

    private

    def reconcile_orders(admin, shop, filter)
      cursor = nil
      seen_cursors = Set.new
      loop do
        order_ids, next_cursor = admin.orders_page(filter, cursor)
        if next_cursor && !seen_cursors.add?(next_cursor)
          raise Admin::Error, "Admin API repeated a reconciliation page cursor"
        end

        order_ids.each do |order_id|
          entries = Payments.entries(admin.order_transactions(order_id))
          @storage.connect do |db|
            Storage.transaction(db) { Payments.apply(db, shop, order_id, entries) }
          end
        end

        break unless next_cursor

        cursor = next_cursor
      end
    end

    def read_checkpoint(db, shop)
      db.get_first_value("SELECT synced_through FROM checkpoints WHERE shop = ?", [shop])
    end

    def advance_checkpoint(shop, upper)
      @storage.connect do |db|
        Storage.transaction(db) do
          current = read_checkpoint(db, shop)
          if current.nil?
            db.execute("INSERT INTO checkpoints (shop, synced_through) VALUES (?, ?)", [shop, upper])
          elsif Time.iso8601(current) >= Time.iso8601(upper)
            next current
          else
            db.execute("UPDATE checkpoints SET synced_through = ? WHERE shop = ?", [upper, shop])
          end
          db.execute("DELETE FROM reconciliation_starts WHERE shop = ?", [shop])
          upper
        end
      end
    end
  end
end
