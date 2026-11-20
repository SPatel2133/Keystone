require "minitest/autorun"
require_relative "../../lib/event_consumer/bundle"
require_relative "../support/shopify_scenarios"

class ShopifyStatusTest < Minitest::Test
  include ShopifyFixture

  def status(run, *shops)
    stdout, stderr, process = run.command("bin/shopify-status", *shops)
    assert process.exited?, stderr
    [JSON.parse(stdout).fetch("shops"), process.exitstatus]
  end

  def test_status_reports_backlog_failures_reconciliation_and_provenance_per_shop
    ShopifyFixture.run do |run|
      shops, code = status(run)
      assert_equal 2, code
      assert_equal [ALPHA, BETA], shops.map { |shop| shop["shop"] }
      assert_equal ["reconciliation has never completed"], shops.first.fetch("reasons")
      assert_equal [], shops.first.fetch("totals")

      run.configure(max_attempts: 1)
      run.admin.order([ShopifyScenarios.sale])
      run.admin.order([], id: OTHER_ORDER)
      run.admin.arrange(ALPHA, "OrderPayments", OTHER_ORDER, { errors: [{ message: "outage" }] }, code: 503)
      run.with_endpoint do
        assert_equal 200, run.deliver("sale")
        assert_equal 200, run.deliver("poison", payload: { id: 102 })
        assert_equal 200, run.deliver("waiting", payload: { id: 102 })
      end
      run.read("UPDATE inbox SET received_at = received_at - 3600 WHERE webhook_id = 'waiting'")
      run.worker
      run.worker(success: false)
      run.admin.page([])
      run.reconcile

      alpha, = status(run, ALPHA)
      alpha = alpha.fetch(0)
      assert_equal "attention", alpha.fetch("health")
      assert_equal ["1 parked delivery needs operator review", alpha.fetch("reasons")[1]], alpha.fetch("reasons")
      assert_match(/\Aoldest pending delivery has waited 36\d\ds\z/, alpha.fetch("reasons")[1])
      deliveries = alpha.fetch("deliveries")
      assert_equal [1, 0, 1, 1, 1, 1], deliveries.values_at("pending", "failing", "parked", "processed",
                                                           "max_attempts_seen", "max_attempts_allowed")
      assert_equal 0, deliveries.fetch("pending_without_receipt_time")
      reconciliation = alpha.fetch("reconciliation")
      assert_nil reconciliation["open_run"]
      assert_equal [1, 1, 0], reconciliation.fetch("last_completed_run").values_at("id", "pages", "orders")
      assert_operator reconciliation.fetch("checkpoint_age_seconds"), :<=, 5
      assert_equal({ "total" => 1, "from_webhooks" => 1, "repaired_by_reconciliation" => 0, "unknown_source" => 0 },
                   alpha.fetch("transactions"))
      assert_equal ShopifyScenarios::BEFORE.fetch("totals"), alpha.fetch("totals")

      # Shops are isolated: beta has no backlog of alpha's work.
      beta, = status(run, BETA)
      assert_equal 0, beta.fetch(0).fetch("deliveries").fetch("pending")

      # A failed reconciliation run is visible with its progress and error.
      run.admin.page([ORDER], next_cursor: "page-2")
      run.admin.arrange(ALPHA, "ReconcileOrders", "page-2", { errors: [{ message: "outage" }] }, code: 503)
      run.read("UPDATE checkpoints SET synced_through = ?", [(Time.now.utc - 3 * 3600).iso8601])
      run.reconcile(success: false)
      run.json("bin/shopify-deliveries", "retry", ALPHA, "poison")
      run.admin.order([], id: OTHER_ORDER)
      run.worker
      run.worker
      alpha, code = status(run, ALPHA)
      alpha = alpha.fetch(0)
      assert_equal 2, code
      open_run = alpha.fetch("reconciliation").fetch("open_run")
      assert_equal ["failed", 1, 1, "Admin API returned HTTP 503"], open_run.values_at("status", "pages", "orders", "last_error")
      assert_equal ["reconciliation run 2 failed: Admin API returned HTTP 503"], alpha.fetch("reasons").grep(/run/)
      assert_equal 1, alpha.fetch("reasons").grep(/checkpoint is \d+s old/).size

      run.admin.page([ORDER], after: "page-2")
      run.reconcile
      alpha, code = status(run, ALPHA)
      assert_equal [0, "ok", []], [code, alpha.fetch(0).fetch("health"), alpha.fetch(0).fetch("reasons")]
    end
  end

  def test_status_surfaces_unreadable_totals_and_rejects_bad_arguments
    ShopifyFixture.run do |run|
      assert_empty run.summary.fetch("totals")
      run.read("INSERT INTO transactions (shop, transaction_id, order_id, currency, kind, amount) VALUES (?, ?, ?, ?, ?, ?)",
               [ALPHA, "gid://shopify/OrderTransaction/9", ORDER, "CASH", "SALE", "1.00"])
      shops, code = status(run, ALPHA)
      assert_equal 2, code
      assert_match(/currency/, shops.first.fetch("totals_error"))
      assert_equal 1, shops.first.fetch("transactions").fetch("unknown_source")

      [["unknown.myshopify.com"], [ALPHA, BETA]].each do |arguments|
        stdout, stderr, process = run.command("bin/shopify-status", *arguments)
        assert_equal 1, process.exitstatus
        assert_empty stdout
        assert_match(/ArgumentError/, stderr)
      end
    end
  end

  def test_status_counts_over_refunded_orders_once_across_currencies
    ShopifyFixture.run do |run|
      run.admin.order([
        ShopifyFixture.transaction("gid://shopify/OrderTransaction/301", "SALE", "10.00", "CAD"),
        ShopifyFixture.transaction("gid://shopify/OrderTransaction/302", "REFUND", "11.00", "CAD"),
        ShopifyFixture.transaction("gid://shopify/OrderTransaction/303", "SALE", "20.00", "USD"),
        ShopifyFixture.transaction("gid://shopify/OrderTransaction/304", "REFUND", "21.00", "USD")
      ])
      run.with_endpoint { assert_equal 200, run.deliver("multi-currency-over-refund") }
      run.worker

      shops, = status(run, ALPHA)
      assert_equal 1, shops.first.fetch("payments").fetch("orders_refunded_beyond_collected")
      stdout, = run.command("bin/shopify-status", "--prometheus", ALPHA)
      assert_includes stdout, 'shopify_ledger_payment_review{shop="alpha.myshopify.com",reason="refund_exceeds_payments"} 1'
    end
  end
end
