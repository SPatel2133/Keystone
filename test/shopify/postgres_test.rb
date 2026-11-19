require "minitest/autorun"
require_relative "../../lib/event_consumer/bundle"
require_relative "../support/shopify_fixture"
require_relative "../support/shopify_fuzz"

# Runs when SHOPIFY_LEDGER_POSTGRES_URL points at a disposable database (CI uses
# a service container). Every test drops and recreates the ledger tables.
class ShopifyPostgresTest < Minitest::Test
  include ShopifyFixture

  URL = ENV["SHOPIFY_LEDGER_POSTGRES_URL"]

  def setup
    skip "set SHOPIFY_LEDGER_POSTGRES_URL to run the PostgreSQL tests" unless URL
    require_relative "../../lib/shopify_ledger/postgres"
    @db = ShopifyLedger::Postgres::Database.new(URL)
    @db.execute("DROP TABLE IF EXISTS #{ShopifyLedger::Postgres::TABLES.join(', ')}")
    @db.migrate
  end

  def teardown
    @db&.close
  end

  def order_gid(number) = "gid://shopify/Order/#{number}"

  def arrange_order(run, number, amount, latency: 0)
    body = { data: { order: { id: order_gid(number),
                              transactions: [ShopifyFixture.transaction("gid://shopify/OrderTransaction/#{number}", "SALE", amount)],
                              transactionsCount: { count: 1, precision: "EXACT" } } } }
    run.admin.arrange(ALPHA, "OrderPayments", order_gid(number), body) { sleep latency }
  end

  def receive(webhook_id, number)
    ShopifyLedger::Postgres.receive(@db, shop: ALPHA, webhook_id: webhook_id, topic: "orders/updated", order_id: order_gid(number))
  end

  def worker(run, *arguments, seam: nil)
    relative = seam ? "test/support/shopify-pg-worker-with-hooks" : "bin/shopify-pg-worker"
    run.command(relative, *arguments, seam: seam)
  end

  def net(run)
    stdout, stderr, status = worker(run, "summary", ALPHA)
    assert status.success?, stderr
    JSON.parse(stdout).fetch("totals").fetch(0).fetch("net")
  end

  def test_workers_on_four_machines_fetch_each_delivery_once_with_skip_locked
    ShopifyFixture.run do |run|
      1.upto(40) do |number|
        arrange_order(run, number, "#{number}.25", latency: 0.05)
        assert receive("delivery-#{number}", number)
      end
      refute receive("delivery-1", 1), "a redelivered webhook must not be inserted twice"
      workers = 1.upto(4).map do |machine|
        ENV["SHOPIFY_LEDGER_WORKER_ID"] = "machine-#{machine}"
        run.spawn("bin/shopify-pg-worker", "--drain")
      ensure
        ENV.delete("SHOPIFY_LEDGER_WORKER_ID")
      end
      counts = workers.map do |stdin, stdout, stderr, waiter|
        stdin.close
        output = stdout.read
        stderr.read
        assert waiter.value.success?
        JSON.parse(output).fetch("processed")
      end
      assert_equal 40, counts.sum
      assert_operator counts.count(&:positive?), :>, 1, "work should spread across machines: #{counts}"
      assert_equal 40, run.admin.requests.size
      assert_equal [[40, 0]], @db.execute("SELECT SUM(processed), COUNT(claimed_by) FROM inbox")
      assert_equal "830.00", net(run)
    end
  end

  def test_a_worker_killed_before_commit_keeps_its_lease_until_it_expires
    ShopifyFixture.run do |run|
      arrange_order(run, 1, "100.00")
      receive("sale", 1)
      _stdout, _stderr, status = worker(run, "--once", seam: "before_commit")
      assert_equal 9, status.termsig
      assert_equal [[0, 0]], [[@db.get_first_value("SELECT processed FROM inbox"), @db.get_first_value("SELECT COUNT(*) FROM transactions")]]
      assert_operator @db.get_first_value("SELECT claimed_until FROM inbox"), :>, Time.now.to_i

      stdout, = worker(run, "--once")
      assert_equal({ "status" => "idle" }, JSON.parse(stdout), "the dead worker's lease has not expired")
      @db.execute("UPDATE inbox SET claimed_until = 0")
      stdout, = worker(run, "--once")
      assert_equal({ "status" => "processed" }, JSON.parse(stdout))
      assert_equal "100.00", net(run)
    end
  end

  def test_a_worker_killed_after_commit_never_counts_a_payment_twice
    ShopifyFixture.run do |run|
      arrange_order(run, 1, "100.00")
      receive("sale", 1)
      _stdout, _stderr, status = worker(run, "--once", seam: "after_commit")
      assert_equal 9, status.termsig
      assert_equal [[1, nil]], @db.execute("SELECT processed, claimed_by FROM inbox")
      receive("sale-again", 1)
      stdout, = worker(run, "--once")
      assert_equal({ "status" => "processed" }, JSON.parse(stdout))
      assert_equal [[1]], @db.execute("SELECT COUNT(*) FROM transactions")
      assert_equal "100.00", net(run)
    end
  end

  def test_admin_failures_back_off_and_park
    ShopifyFixture.run do |run|
      run.configure(max_attempts: 2)
      run.admin.arrange(ALPHA, "OrderPayments", order_gid(1), { errors: [{ message: "down" }] }, code: 500)
      receive("sale", 1)
      stdout, = worker(run, "--once")
      assert_equal({ "status" => "retry" }, JSON.parse(stdout))
      stdout, = worker(run, "--once")
      assert_equal({ "status" => "idle" }, JSON.parse(stdout), "the retry waits for its backoff")
      @db.execute("UPDATE inbox SET next_attempt_at = 0")
      stdout, = worker(run, "--once")
      assert_equal({ "status" => "parked" }, JSON.parse(stdout))
      assert_equal [[0, 2, nil]], @db.execute("SELECT processed, attempts, claimed_by FROM inbox")
      refute_nil @db.get_first_value("SELECT parked_at FROM inbox")
    end
  end

  def test_fixed_fuzz_seeds_keep_every_invariant_on_postgres
    report = ShopifyFuzz.campaign(seed: 20_261_119, runs: 25, steps: 200, backend: :postgres)
    assert_empty report["failures"], JSON.pretty_generate(report["failures"])
    assert_operator report["operations"].fetch("crash_before_commit"), :>, 0
  end

  def test_fuzz_seeds_with_real_drains_on_several_machines_and_killed_workers
    report = ShopifyFuzz.campaign(seed: 7, runs: 3, steps: 60, processes: true, backend: :postgres)
    assert_empty report["failures"], JSON.pretty_generate(report["failures"])
    assert_operator report["operations"].fetch("kill_mid_fetch"), :>, 0
  end

  def test_webhooks_ingest_into_postgres_end_to_end
    ShopifyFixture.run do |run|
      arrange_order(run, 101, "100.00")
      ENV["SHOPIFY_LEDGER_INBOX"] = "postgres"
      run.with_endpoint do
        assert_equal 200, run.deliver("sale")
        assert_equal 200, run.deliver("sale"), "a redelivery is acknowledged once stored"
        assert_equal 409, run.deliver("sale", topic: "refunds/create"), "the same delivery ID cannot change identity"
        assert_equal 401, run.deliver("forged", signature: "bad")
      end
      assert_equal [[ALPHA, "sale", ORDER]], @db.execute("SELECT shop, webhook_id, order_id FROM inbox")
      refute File.exist?(run.database), "SQLite must not receive deliveries"
      stdout, = worker(run, "--once")
      assert_equal({ "status" => "processed" }, JSON.parse(stdout))
      assert_equal "100.00", net(run)
    ensure
      ENV.delete("SHOPIFY_LEDGER_INBOX")
    end
  end

  def test_reconciliation_repairs_missed_webhooks_and_resumes_on_postgres
    ShopifyFixture.run do |run|
      arrange_order(run, 1, "10.00")
      arrange_order(run, 2, "20.00")
      run.admin.page([order_gid(1)], next_cursor: "p1")
      run.admin.arrange(ALPHA, "ReconcileOrders", "p1", { errors: [{ message: "down" }] }, code: 500)
      _stdout, _stderr, status = worker(run, "reconcile", ALPHA)
      assert_equal 1, status.exitstatus
      assert_equal [["failed", 1, "p1"]], @db.execute("SELECT status, pages, cursor FROM reconciliation_runs")
      assert_equal "10.00", net(run)

      run.admin.page([order_gid(2)], after: "p1")
      stdout, stderr, status = worker(run, "reconcile", ALPHA)
      assert status.success?, stderr
      refute_nil JSON.parse(stdout).fetch("synced_through")
      assert_equal [["completed", 2]], @db.execute("SELECT status, pages FROM reconciliation_runs ORDER BY id LIMIT 1")
      assert_equal "30.00", net(run)
      # The retry resumed at the saved cursor; then a fresh window scanned from the start.
      pages = run.admin.requests.select { |request| request["operation"] == "ReconcileOrders" }.map { |request| request["variables"]["after"] }
      assert_equal [nil, "p1", "p1", nil, "p1"], pages
    end
  end

  def test_status_reports_postgres_deliveries_reconciliation_and_payments
    ShopifyFixture.run do |run|
      arrange_order(run, 1, "10.00")
      receive("sale", 1)
      run.admin.arrange(ALPHA, "OrderPayments", order_gid(2), { errors: [{ message: "down" }] }, code: 500)
      receive("broken", 2)
      worker(run, "--drain")
      run.admin.page([order_gid(1)])
      stdout, = worker(run, "reconcile", ALPHA)
      refute_nil JSON.parse(stdout).fetch("synced_through")
      stdout, stderr, status = worker(run, "status", ALPHA)
      assert_equal 0, status.exitstatus, stderr
      shop = JSON.parse(stdout).fetch("shops").first
      assert_equal "ok", shop.fetch("health")
      assert_equal [1, 1, 1], shop.fetch("deliveries").values_at("processed", "pending", "failing")
      assert_equal({ "total" => 1, "from_webhooks" => 1, "repaired_by_reconciliation" => 0, "unknown_source" => 0 },
                   shop.fetch("transactions"))
      assert_equal "10.00", shop.fetch("totals").first.fetch("net")
      assert_equal 0, shop.fetch("payments").fetch("open_transactions")
    end
  end

  def test_operators_list_retry_and_audit_deliveries_on_postgres
    ShopifyFixture.run do |run|
      run.configure(max_attempts: 1)
      run.admin.arrange(ALPHA, "OrderPayments", order_gid(1), { errors: [{ message: "down" }] }, code: 500)
      receive("sale", 1)
      worker(run, "--once")
      stdout, = worker(run, "deliveries", "list", ALPHA, "parked")
      parked = JSON.parse(stdout).fetch("deliveries")
      assert_equal [["sale", "parked", 1]], parked.map { |row| row.values_at("webhook_id", "state", "attempts") }

      arrange_order(run, 1, "10.00")
      stdout, stderr, status = worker(run, "deliveries", "retry", ALPHA, "sale")
      assert status.success?, stderr
      assert_equal ["pending", 1], JSON.parse(stdout).values_at("state", "requeues")
      worker(run, "--once")
      _stdout, stderr, status = worker(run, "deliveries", "retry", ALPHA, "sale")
      assert_equal 1, status.exitstatus
      assert_match(/already processed/, stderr)

      stdout, stderr, status = worker(run, "audit", ALPHA, "--order", order_gid(1))
      assert status.success?, stderr
      audit = JSON.parse(stdout)
      assert_equal [["delivery", "sale"]], audit.fetch("transactions").map { |row| row.values_at("recorded_by", "reference") }
      assert_equal [["sale", "processed", 1]], audit.fetch("deliveries").map { |row| row.values_at("webhook_id", "state", "requeues") }
      assert_equal "10.00", audit.fetch("totals").first.fetch("net")
    end
  end

  def test_webhook_ingest_reconnects_after_the_database_drops_its_connection
    ShopifyFixture.run do |run|
      ENV["SHOPIFY_LEDGER_INBOX"] = "postgres"
      run.with_endpoint do
        assert_equal 200, run.deliver("before")
        @db.execute("SELECT pg_terminate_backend(pid) FROM pg_stat_activity " \
                    "WHERE datname = current_database() AND pid <> pg_backend_pid()")
        assert_equal 503, run.deliver("during"), "the delivery is not acknowledged, so Shopify retries it"
        assert_equal 200, run.deliver("during")
        assert_equal 200, run.deliver("after")
      end
      assert_equal [["before"], ["during"], ["after"]], @db.execute("SELECT webhook_id FROM inbox ORDER BY id")
    ensure
      ENV.delete("SHOPIFY_LEDGER_INBOX")
    end
  end

  # Found in review: two workers completing different deliveries of one order
  # insert the same payment; the second must see the first, not a unique violation.
  def test_concurrent_applies_of_the_same_order_do_not_collide
    entries = ShopifyLedger::Payments.entries(JSON.parse(JSON.generate([ShopifyFixture.transaction(SALE, "SALE", "100.00")])))
    other = ShopifyLedger::Postgres::Database.new(URL)
    @db.transaction do
      ShopifyLedger::Payments.apply(@db, ALPHA, ORDER, entries, source: "delivery:a")
      waiting = Thread.new { other.transaction { ShopifyLedger::Payments.apply(other, ALPHA, ORDER, entries, source: "delivery:b") } }
      sleep 0.3
      assert waiting.alive?, "the second apply waits for the first commit"
      @waiting = waiting
    end
    assert_equal 0, @waiting.value
    assert_equal [[1, "delivery:a"]], @db.execute("SELECT COUNT(*), MIN(source) FROM transactions")
  ensure
    other&.close
  end

  def test_completed_deliveries_record_their_last_attempt
    ShopifyFixture.run do |run|
      arrange_order(run, 1, "10.00")
      receive("sale", 1)
      worker(run, "--once")
      refute_nil @db.get_first_value("SELECT last_attempt_at FROM inbox")
    end
  end

  # Found by fuzzer: workers completing different deliveries of one order at
  # once locked inbox rows in different orders and could deadlock.
  def test_concurrent_workers_on_the_same_orders_never_deadlock
    ShopifyFixture.run do |run|
      ENV["SHOPIFY_LEDGER_CONFIG"] = File.join(File.dirname(run.database), "config.json")
      ENV["SHOPIFY_LEDGER_ALLOW_HTTP_LOOPBACK"] = "1"
      config = ShopifyLedger::Config.load
      1.upto(20) do |number|
        arrange_order(run, number, "1.00", latency: 0.01)
        3.times { |update| receive("d-#{number}-#{update}", number) }
      end
      connections = Array.new(4) { ShopifyLedger::Postgres::Database.new(URL) }
      threads = connections.each_with_index.map do |db, index|
        Thread.new { ShopifyLedger::Postgres::Worker.new(config, db, owner: "t#{index}").drain }
      end
      Timeout.timeout(60) { threads.each(&:value) }
      assert_equal [[60]], @db.execute("SELECT SUM(processed) FROM inbox")
      assert_equal "20.00", ShopifyLedger::Payments.summary(@db, ALPHA).first.fetch("net")
    ensure
      connections&.each(&:close)
      ENV.delete("SHOPIFY_LEDGER_CONFIG")
      ENV.delete("SHOPIFY_LEDGER_ALLOW_HTTP_LOOPBACK")
    end
  end

  # Found in review: the PostgreSQL worker lacked SQLite's attempts guard, so a
  # failure that began before an operator retry parked the requeued delivery.
  def test_operator_retry_during_a_failing_fetch_is_not_overwritten_on_postgres
    ShopifyFixture.run do |run|
      run.configure(max_attempts: 1)
      down = { errors: [{ message: "down" }] }
      receive("sale", 1)
      retried = false
      run.admin.arrange(ALPHA, "OrderPayments", order_gid(1), down, code: 500) do
        unless retried
          retried = true
          worker(run, "deliveries", "retry", ALPHA, "sale")
          arrange_order(run, 1, "10.00")
        end
      end
      stdout, stderr, status = worker(run, "--once")
      assert_equal 0, status.exitstatus, stderr
      assert_equal({ "status" => "processed" }, JSON.parse(stdout))
      assert_equal [[1, nil, 0, 1]], @db.execute("SELECT processed, parked_at, attempts, requeues FROM inbox")
    end
  end
end
