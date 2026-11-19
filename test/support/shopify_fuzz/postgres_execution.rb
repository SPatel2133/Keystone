module ShopifyFuzz
  # The same operation lists against the PostgreSQL backend. Backups,
  # maintenance and moves are SQLite-only, so they do nothing here.
  class PostgresExecution < Execution
    URL = ENV["SHOPIFY_LEDGER_POSTGRES_URL"]

    private

    def setup(orders)
      super
      require_relative "../../../lib/shopify_ledger/postgres"
      @pg&.close
      @pg = ShopifyLedger::Postgres::Database.new(URL || raise(ArgumentError, "set SHOPIFY_LEDGER_POSTGRES_URL"))
      @pg.execute("DROP TABLE IF EXISTS #{ShopifyLedger::Postgres::TABLES.join(', ')}")
      @pg.migrate
    end

    def receive(shop, webhook_id, topic, order_id)
      ShopifyLedger::Postgres.receive(@pg, shop: shop, webhook_id: webhook_id, topic: topic, order_id: order_id)
    end

    def pg_worker(owner = "fuzz-machine") = ShopifyLedger::Postgres::Worker.new(@config, @pg, owner: owner)

    def run_worker(_a, **hooks)
      outcome = pg_worker.run_once(**hooks)
      fail!("unexpected worker outcome #{outcome.inspect}") unless %w[idle processed retry parked].include?(outcome)
      outcome
    rescue Crash
      "crashed"
    end

    # A worker on another machine died holding a lease.
    def op_orphan_claim(a, _b, _c)
      ids = @pg.execute("SELECT id FROM inbox WHERE processed = 0 AND parked_at IS NULL ORDER BY id").flatten
      id = pick(ids, a) or return
      @pg.execute("UPDATE inbox SET claimed_by = 'dead-machine', claimed_until = ? WHERE id = ?", [Time.now.to_i + 60, id])
    end

    # Time passes: backoffs and leases expire.
    def op_advance_time(*)
      @pg.execute(<<~SQL)
        UPDATE inbox SET next_attempt_at = 0,
                         claimed_until = CASE WHEN claimed_until IS NULL THEN NULL ELSE 0 END
        WHERE processed = 0
      SQL
    end

    def op_operator_retry(a, _b, _c)
      parked = @pg.execute("SELECT shop, webhook_id FROM inbox WHERE parked_at IS NOT NULL ORDER BY id")
      choice = pick(parked, a) or return
      ShopifyLedger::Deliveries.new(@config, store: ShopifyLedger::Postgres::Store.new(@pg)).retry(*choice)
    end

    def worker_executable = "bin/shopify-pg-worker"

    def reconcile(shop)
      @clock += 600
      store = ShopifyLedger::Postgres::Store.new(@pg)
      ShopifyLedger::Reconciliation.new(@config, clock: -> { @clock }, store: store).run(shop)
      true
    rescue ShopifyLedger::Admin::Error, ShopifyLedger::Payments::Error
      false
    end

    %w[backup maintain move_shop].each do |op|
      define_method("op_#{op}") { |*| nil }
    end

    def check_invariants(path, live: true)
      return unless path == @config.database

      rows = @pg.execute(<<~SQL)
        SELECT shop, transaction_id, order_id, currency, kind, amount, presentment_currency, presentment_amount,
               parent_transaction_id
        FROM transactions
      SQL
      verify_rows(rows, @pg.execute(EVENTS_SQL))
      claimed = @pg.get_first_value("SELECT COUNT(*) FROM inbox WHERE processed = 1 AND claimed_by IS NOT NULL")
      fail!("#{claimed} processed deliveries still hold a lease") unless claimed.zero?
      @pg.execute("SELECT shop, synced_through FROM checkpoints").each do |shop, synced|
        previous = @checkpoints[shop]
        fail!("checkpoint for #{shop} moved backwards from #{previous} to #{synced}") if previous && synced < previous
        @checkpoints[shop] = synced
      end
    end

    def settle
      @orders.each_key { |key| arrange_truth(*key) }
      SHOPS.each { |shop| arrange_pages(shop) }
      10.times do
        @pg.execute("UPDATE inbox SET parked_at = NULL, attempts = 0 WHERE parked_at IS NOT NULL")
        op_advance_time
        pg_worker("settle-machine").drain
        break if @pg.get_first_value("SELECT COUNT(*) FROM inbox WHERE processed = 0").zero?
      end
      SHOPS.each { |shop| fail!("settle reconciliation failed for #{shop}") unless reconcile(shop) }
      check_invariants(@config.database)
      pending = @pg.get_first_value("SELECT COUNT(*) FROM inbox WHERE processed = 0")
      fail!("#{pending} deliveries never completed") unless pending.zero?
      stale = @pg.execute("SELECT shop, transaction_id, status FROM payment_events")
                 .reject { |shop, id, status| @truth.fetch([shop, id])[:status] == status }
      fail!("statuses still lag after settle: #{stale.first(3).inspect}") unless stale.empty?
      stored = @pg.execute("SELECT shop, transaction_id FROM transactions").to_set
      expected = @truth.keys.select { |shop, id| expected_row(shop, id) }.to_set
      fail!("missing after settle: #{(expected - stored).to_a.first(3).inspect}") unless (expected - stored).empty?
      SHOPS.each do |shop|
        fail!("totals for #{shop} differ from the model") unless ShopifyLedger::Payments.summary(@pg, shop) == model_totals(shop)
      end
    ensure
      @pg&.close
      @pg = nil
    end
  end
end
