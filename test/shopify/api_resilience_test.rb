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

  def test_retry_delay_is_exponential_and_honours_a_capped_retry_after
    assert_equal [0.25, 0.5, 1.0, 2.0, 2.0], (1..5).map { |attempt| ShopifyLedger::Admin.delay(attempt) }
    assert_equal 1.5, ShopifyLedger::Admin.delay(1, 1.5)
    assert_equal 2.0, ShopifyLedger::Admin.delay(1, 600)
  end
end
