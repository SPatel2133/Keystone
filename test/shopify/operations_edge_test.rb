require "minitest/autorun"
require "bigdecimal"
require_relative "../../lib/event_consumer/bundle"
require_relative "../support/shopify_scenarios"

class ShopifyOperationsEdgeTest < Minitest::Test
  include ShopifyFixture

  def tx(number, kind, amount, currency = "CAD")
    ShopifyFixture.transaction("gid://shopify/OrderTransaction/#{number}", kind, amount, currency)
  end

  def status(run, *shops)
    stdout, _stderr, process = run.command("bin/shopify-status", *shops)
    [JSON.parse(stdout).fetch("shops"), process.exitstatus]
  end

  def test_huge_amounts_and_currencies_agree_across_summary_status_and_audit
    ShopifyFixture.run do |run|
      run.admin.order([tx(1, "SALE", "99999999999999999999.99"), tx(2, "CAPTURE", "0.01"),
                       tx(3, "REFUND", "0.000001", "BHD"), tx(4, "SALE", "12345678901234567890.123", "BHD")])
      run.with_endpoint { assert_equal 200, run.deliver("huge") }
      run.worker

      expected = [
        { "currency" => "BHD", "collected" => "12345678901234567890.123", "refunded" => "0.000001",
          "net" => "12345678901234567890.122999" },
        { "currency" => "CAD", "collected" => "100000000000000000000.00", "refunded" => "0.00",
          "net" => "100000000000000000000.00" }
      ]
      assert_equal expected, run.summary.fetch("totals")
      shops, = status(run, ALPHA)
      assert_equal expected, shops.first.fetch("totals")
      assert_equal expected, run.json("bin/shopify-audit", ALPHA).fetch("totals")
      assert_equal expected, run.json("bin/shopify-audit", ALPHA, "--order", ORDER).fetch("totals")
    end
  end

  def test_operating_commands_never_cross_shops
    ShopifyFixture.run do |run|
      run.configure(max_attempts: 1)
      run.admin.arrange(ALPHA, "OrderPayments", ORDER, { errors: [{ message: "gone" }] }, code: 404)
      run.admin.order([ShopifyScenarios.sale], shop: BETA)
      run.with_endpoint do
        # Delivery IDs are only unique per shop; both shops reuse "shared".
        assert_equal 200, run.deliver("shared")
        assert_equal 200, run.deliver("shared", shop: BETA)
      end
      run.json("bin/shopify-worker", "--drain", success: false)

      assert_equal %w[parked], run.json("bin/shopify-deliveries", "list", ALPHA, "--state", "all")
                                  .fetch("deliveries").map { |row| row.fetch("state") }
      assert_equal %w[processed], run.json("bin/shopify-deliveries", "list", BETA, "--state", "all")
                                     .fetch("deliveries").map { |row| row.fetch("state") }
      # Retrying BETA's processed delivery is refused and leaves ALPHA's parked one alone.
      refused = run.json("bin/shopify-deliveries", "retry", BETA, "shared", success: false)
      assert_equal "delivery already processed", refused.fetch("refused")
      assert_equal [[ALPHA, 0, 1], [BETA, 1, 0]],
                   run.read("SELECT shop, processed, parked_at IS NOT NULL FROM inbox ORDER BY shop")

      shops, code = status(run)
      assert_equal 2, code
      parked = shops.to_h { |shop| [shop["shop"], shop.fetch("deliveries").fetch("parked")] }
      assert_equal({ ALPHA => 1, BETA => 0 }, parked)
      assert shops.find { |shop| shop["shop"] == ALPHA }.fetch("reasons").any? { |reason| reason.include?("parked") }
      refute shops.find { |shop| shop["shop"] == BETA }.fetch("reasons").any? { |reason| reason.include?("parked") }
      assert_empty run.json("bin/shopify-audit", ALPHA).fetch("transactions")
      assert_equal [ShopifyScenarios::SALE], run.json("bin/shopify-audit", BETA).fetch("transactions").map { |row| row["transaction_id"] }
      assert_equal [%w[shared parked]],
                   run.json("bin/shopify-audit", ALPHA, "--order", ORDER).fetch("deliveries").map { |d| d.values_at("webhook_id", "state") }
    end
  end

  def test_a_repeated_page_cursor_fails_the_run_instead_of_looping_and_resumes_once_fixed
    ShopifyFixture.run do |run|
      run.admin.order([ShopifyScenarios.sale])
      run.admin.order([ShopifyScenarios.refund], id: OTHER_ORDER)
      run.admin.page([ORDER], next_cursor: "c1")
      run.admin.page([OTHER_ORDER], after: "c1", next_cursor: "c1")
      failure = run.reconcile(success: false)
      assert_match(/repeated a reconciliation page cursor/, failure.fetch("stderr"))
      # Page 1 is durable; the repeated page was never saved as progress.
      assert_equal [["failed", 1, "c1"]], run.read("SELECT status, pages, cursor FROM reconciliation_runs")
      assert_equal "100.00", run.summary.fetch("totals").first.fetch("net")

      run.admin.page([OTHER_ORDER], after: "c1")
      run.reconcile
      assert_equal "75.00", run.summary.fetch("totals").first.fetch("net")
      assert_equal [["completed", 2]], run.read("SELECT status, pages FROM reconciliation_runs ORDER BY id LIMIT 1")
    end
  end

  def test_audit_still_lists_rows_when_a_stored_currency_is_invalid
    ShopifyFixture.run do |run|
      assert_empty run.summary.fetch("totals")
      run.read("INSERT INTO transactions (shop, transaction_id, order_id, currency, kind, amount) VALUES (?, ?, ?, ?, ?, ?)",
               [ALPHA, "gid://shopify/OrderTransaction/9", ORDER, "CASH", "SALE", "1.00"])
      shop = run.json("bin/shopify-audit", ALPHA)
      refute shop.key?("totals")
      assert_match(/invalid currency/, shop.fetch("totals_error"))
      assert_equal [%w[CASH unknown]], shop.fetch("transactions").map { |row| row.values_at("currency", "recorded_by") }
      order = run.json("bin/shopify-audit", ALPHA, "--order", ORDER)
      assert_match(/invalid currency/, order.fetch("totals_error"))
      assert_equal 1, order.fetch("transactions").size
    end
  end
end
