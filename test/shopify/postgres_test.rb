require "minitest/autorun"
require_relative "../../lib/event_consumer/bundle"
require_relative "../support/shopify_fixture"

# Runs when SHOPIFY_LEDGER_POSTGRES_URL points at a disposable database (CI uses
# a service container). Every test drops and recreates the ledger tables.
class ShopifyPostgresTest < Minitest::Test
  include ShopifyFixture

  URL = ENV["SHOPIFY_LEDGER_POSTGRES_URL"]

  def setup
    skip "set SHOPIFY_LEDGER_POSTGRES_URL to run the PostgreSQL tests" unless URL
    require_relative "../../lib/shopify_ledger/postgres"
    @db = ShopifyLedger::Postgres::Database.new(URL)
    @db.execute("DROP TABLE IF EXISTS inbox, transactions, payment_events")
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
end
