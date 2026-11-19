require "time"
require "set"
require_relative "admin"
require_relative "log"
require_relative "payments"
require_relative "storage"

module ShopifyLedger
  # Repairs missed webhooks by scanning orders updated in a fixed time window.
  #
  # Each window is a durable reconciliation_runs row. After every fully applied
  # page the run stores the next page cursor, so a failed or killed run resumes
  # at the first unapplied page instead of rescanning the whole window. Resuming
  # is safe: the upper bound is fixed, so an order updated after the failure
  # leaves this window and falls inside the next one (which starts OVERLAP
  # before this window's end).
  class Reconciliation
    FIRST_LOOKBACK = 7 * 24 * 60 * 60
    OVERLAP = 5 * 60

    Run = Struct.new(:id, :window_start, :window_end, :cursor, :pages, :resumed, keyword_init: true)

    # Runs, checkpoints and payments live in the shop's SQLite file by default,
    # or in Postgres::Store. The SQL here is valid in both.
    def initialize(config, clock: -> { Time.now }, store: nil)
      @config = config
      @clock = clock
      @store = store
    end

    # Returns the shop's checkpoint after finishing any interrupted window and
    # then one fresh window ending now.
    def run(shop)
      @storage = @store || Storage::Store.new(@config.database_for(shop))
      admin = Admin.new(@config, shop)
      loop do
        run = open_run(shop)
        return run if run.is_a?(String)

        checkpoint = finish(admin, shop, run)
        return checkpoint unless run.resumed
      end
    end

    private

    def open_run(shop)
      upper = @clock.call.getutc
      now = Time.now.to_i
      @storage.connect do |db|
        @storage.transaction(db) do
          resumable = db.get_first_row(<<~SQL, [now, shop])
            UPDATE reconciliation_runs
            SET status = 'running', attempts = attempts + 1, updated_at = ?, last_error = NULL
            WHERE shop = ? AND status <> 'completed'
            RETURNING id, window_start, window_end, cursor, pages
          SQL
          next build(resumable, resumed: true) if resumable

          checkpoint = read_checkpoint(db, shop)
          next checkpoint if checkpoint && Time.iso8601(checkpoint) > upper

          lower = if checkpoint
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
          row = db.get_first_row(<<~SQL, [shop, lower.utc.iso8601, upper.iso8601, now, now])
            INSERT INTO reconciliation_runs (shop, window_start, window_end, status, started_at, updated_at)
            VALUES (?, ?, ?, 'running', ?, ?)
            RETURNING id, window_start, window_end, cursor, pages
          SQL
          build(row, resumed: false)
        end
      end
    end

    def build(row, resumed:)
      id, window_start, window_end, cursor, pages = row
      Run.new(id: id, window_start: window_start, window_end: window_end, cursor: cursor, pages: pages, resumed: resumed)
    end

    def finish(admin, shop, run)
      filter = "updated_at:>='#{run.window_start}' updated_at:<='#{run.window_end}'"
      Log.event("reconciliation_started", shop: shop, run: run.id, window_start: run.window_start,
                                          window_end: run.window_end, resumed_after_pages: run.resumed ? run.pages : nil)
      reconcile_orders(admin, shop, filter, run)
      checkpoint = complete(shop, run)
      Log.event("reconciliation_completed", shop: shop, run: run.id, synced_through: checkpoint)
      checkpoint
    rescue StandardError => error
      record_failure(run, error)
      Log.event("reconciliation_failed", shop: shop, run: run.id, error: "#{error.class}: #{error.message}")
      raise
    end

    def reconcile_orders(admin, shop, filter, run)
      cursor = run.cursor
      pages = run.pages
      seen_cursors = Set.new([cursor].compact)
      source = "reconciliation:#{run.id}"
      loop do
        @first_request_of_resume = run.resumed && cursor && pages == run.pages
        order_ids, next_cursor = admin.orders_page(filter, cursor)
        @first_request_of_resume = false
        if next_cursor && !seen_cursors.add?(next_cursor)
          raise Admin::Error, "Admin API repeated a reconciliation page cursor"
        end

        order_ids.each do |order_id|
          entries = Payments.entries(admin.order_transactions(order_id))
          @storage.connect do |db|
            @storage.transaction(db) { Payments.apply(db, shop, order_id, entries, source: source) }
          end
        end

        pages += 1
        save_progress(run, pages, order_ids.size, next_cursor)
        break unless next_cursor

        cursor = next_cursor
      end
    end

    # Records a fully applied page. Pages only move forward, so a concurrent
    # reconciler of the same window cannot move the saved cursor backwards.
    def save_progress(run, pages, orders, cursor)
      @storage.connect do |db|
        @storage.transaction(db) do
          db.execute(<<~SQL, [pages, orders, cursor, Time.now.to_i, run.id, pages])
            UPDATE reconciliation_runs SET pages = ?, orders = orders + ?, cursor = ?, updated_at = ?
            WHERE id = ? AND pages < ? AND status <> 'completed'
          SQL
        end
      end
    end

    def record_failure(run, error)
      # A saved cursor that fails on its very first reuse may have expired, so
      # the next attempt rescans the window from the first page. Reapplying
      # pages is idempotent by transaction identity.
      restart = @first_request_of_resume
      @storage.connect do |db|
        @storage.transaction(db) do
          db.execute(<<~SQL, [error.message, Time.now.to_i, restart ? 1 : 0, restart ? 1 : 0, run.id])
            UPDATE reconciliation_runs
            SET status = 'failed', last_error = ?, updated_at = ?,
                cursor = CASE WHEN ? THEN NULL ELSE cursor END,
                pages = CASE WHEN ? THEN 0 ELSE pages END
            WHERE id = ? AND status <> 'completed'
          SQL
        end
      end
    rescue SQLite3::Exception
      # The open run stays 'running' and is resumed by the next attempt.
      nil
    end

    def read_checkpoint(db, shop)
      db.get_first_value("SELECT synced_through FROM checkpoints WHERE shop = ?", [shop])
    end

    def complete(shop, run)
      upper = run.window_end
      @storage.connect do |db|
        @storage.transaction(db) do
          db.execute(<<~SQL, [Time.now.to_i, Time.now.to_i, run.id])
            UPDATE reconciliation_runs SET status = 'completed', cursor = NULL, finished_at = ?, updated_at = ?
            WHERE id = ?
          SQL
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
