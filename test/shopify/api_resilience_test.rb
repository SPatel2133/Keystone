require "minitest/autorun"
require_relative "../../lib/event_consumer/bundle"
require_relative "../support/shopify_scenarios"

class ShopifyApiResilienceTest < Minitest::Test
  include ShopifyFixture

  def order_requests(run)
    run.admin.requests.count { |request| request["operation"] == "OrderPayments" }
  end

  def deliver_one(run)
    run.with_endpoint { assert_equal 200, run.deliver("sale") }
  end

  def test_throttled_and_server_errors_are_retried_within_one_delivery_attempt
    [
      [429, { errors: [{ message: "Throttled" }] }],
      [200, { errors: [{ message: "Throttled", extensions: { code: "THROTTLED" } }] }],
      [502, "<html>bad gateway</html>"]
    ].each do |code, body|
      ShopifyFixture.run do |run|
        run.configure(api_attempts: 3)
        deliver_one(run)
        run.admin.arrange(ALPHA, "OrderPayments", ORDER, body, code: code) { run.admin.order([ShopifyScenarios.sale]) }
        _stdout, stderr, process = run.command("bin/shopify-worker", "--once")
        assert process.success?, stderr
        assert_equal 2, order_requests(run), code
        retry_log = JSON.parse(stderr.lines.find { |line| line.include?("admin_api_retry") })
        assert_equal [ALPHA, "OrderPayments", 1, 0.25], retry_log.values_at("shop", "operation", "attempt", "delay_seconds")
        assert_equal [[1, 0]], run.read("SELECT processed, attempts FROM inbox")
        assert_equal ShopifyScenarios::BEFORE, run.summary
      end
    end
  end

  def test_a_read_timeout_is_retried_within_the_attempt_and_the_limit_is_configurable
    ShopifyFixture.run do |run|
      run.configure(api_attempts: 2, api_read_timeout: 0.2)
      deliver_one(run)
      admin = run.admin
      admin.arrange(ALPHA, "OrderPayments", ORDER, { data: nil }) do
        admin.order([ShopifyScenarios.sale])
        sleep 0.5
      end
      _stdout, stderr, process = run.command("bin/shopify-worker", "--once")
      assert process.success?, stderr
      assert_equal 2, order_requests(run)
      assert_match(/Net::ReadTimeout/, stderr.lines.find { |line| line.include?("admin_api_retry") })
      assert_equal ShopifyScenarios::BEFORE, run.summary

      run.configure(api_read_timeout: 0)
      _stdout, stderr, process = run.command("bin/shopify-worker", "--once")
      refute process.success?
      assert_match(/api_read_timeout must be a number of seconds/, stderr)
    end
  end

  def test_persistent_outage_spends_bounded_attempts_then_defers_the_delivery
    ShopifyFixture.run do |run|
      run.configure(api_attempts: 3)
      deliver_one(run)
      run.admin.arrange(ALPHA, "OrderPayments", ORDER, { errors: [{ message: "down" }] }, code: 503)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      assert_equal({ "status" => "retry" }, run.worker(success: false))
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      assert_equal 3, order_requests(run)
      assert_operator elapsed, :>=, 0.75
      assert_equal [[0, 1, "Admin API returned HTTP 503"]], run.read("SELECT processed, attempts, last_error FROM inbox")
    end
  end

  def test_permanent_errors_are_not_retried
    [[401, { errors: "Invalid API key" }], [200, "not json"],
     [200, { errors: [{ message: "Field does not exist", extensions: { code: "undefinedField" } }] }]].each do |code, body|
      ShopifyFixture.run do |run|
        run.configure(api_attempts: 3)
        deliver_one(run)
        run.admin.arrange(ALPHA, "OrderPayments", ORDER, body, code: code)
        assert_equal({ "status" => "retry" }, run.worker(success: false))
        assert_equal 1, order_requests(run), body.inspect
      end
    end
  end

  def test_reconciliation_page_retry_does_not_skip_or_repeat_pages
    ShopifyFixture.run do |run|
      run.configure(api_attempts: 2)
      run.admin.page([ORDER], next_cursor: "page-2")
      run.admin.order([ShopifyScenarios.sale])
      run.admin.order([ShopifyScenarios.refund], id: OTHER_ORDER)
      run.admin.arrange(ALPHA, "ReconcileOrders", "page-2", { errors: [{ message: "busy" }] }, code: 503) do
        run.admin.page([OTHER_ORDER], after: "page-2")
      end
      run.reconcile
      pages = run.admin.requests.select { |r| r["operation"] == "ReconcileOrders" }.map { |r| r["variables"]["after"] }
      assert_equal [nil, "page-2", "page-2"], pages
      assert_equal ShopifyScenarios::AFTER, run.summary
      assert_equal [["completed", 2, 2]], run.read("SELECT status, pages, orders FROM reconciliation_runs")
    end
  end

  def cost(requested, available, rate = 50.0)
    { cost: { requestedQueryCost: requested, actualQueryCost: requested,
              throttleStatus: { maximumAvailable: 1000.0, currentlyAvailable: available, restoreRate: rate } } }
  end

  def test_query_cost_paces_calls_and_sizes_the_throttle_retry
    ShopifyFixture.run do |run|
      run.configure(api_attempts: 3)
      deliver_one(run)
      throttled = { errors: [{ message: "Throttled", extensions: { code: "THROTTLED" } }], extensions: cost(52, 12) }
      transactions = [ShopifyScenarios.sale]
      success = { data: { order: { id: ORDER, transactions: transactions, transactionsCount: { count: 1, precision: "EXACT" } } },
                  extensions: cost(52, 32) }
      run.admin.arrange(ALPHA, "OrderPayments", ORDER, throttled) { run.admin.arrange(ALPHA, "OrderPayments", ORDER, success) }
      _stdout, stderr, process = run.command("bin/shopify-worker", "--once")
      assert process.success?, stderr
      events = stderr.lines.map { |line| JSON.parse(line) }
      retry_log = events.find { |event| event["event"] == "admin_api_retry" }
      assert_equal 0.8, retry_log.fetch("delay_seconds")
      pacing = events.find { |event| event["event"] == "admin_api_pacing" }
      assert_equal [ALPHA, "OrderPayments", 0.4], pacing.values_at("shop", "operation", "wait_seconds")
      assert_equal ShopifyScenarios::BEFORE, run.summary
    end
  end

  def test_bucket_wait_ignores_missing_or_malformed_cost
    admin = ShopifyLedger::Admin.allocate
    wait = ->(body) { admin.send(:bucket_wait, JSON.parse(JSON.generate(body))) }
    assert_nil wait.call({})
    assert_nil wait.call({ extensions: cost(10, 500) })
    assert_nil wait.call({ extensions: cost(10, 5, 0) })
    assert_nil wait.call({ extensions: cost("10", 5) })
    assert_equal 2.0, wait.call({ extensions: cost(1000, 0) })
  end

  def test_retry_delay_is_exponential_and_honours_a_capped_retry_after
    assert_equal [0.25, 0.5, 1.0, 2.0, 2.0], (1..5).map { |attempt| ShopifyLedger::Admin.delay(attempt) }
    assert_equal 1.5, ShopifyLedger::Admin.delay(1, 1.5)
    assert_equal 2.0, ShopifyLedger::Admin.delay(1, 600)
  end
end
