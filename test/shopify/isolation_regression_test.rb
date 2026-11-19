require "minitest/test"
require_relative "../support/shopify_fixture"

class ShopifyCurrencyTest < Minitest::Test
  include ShopifyFixture

  def test_unknown_currency_defers_entire_delivery_until_corrected
    ShopifyFixture.run do |run|
      sale = ShopifyFixture.transaction(SALE, "SALE", "100.00", "USDC")
      run.admin.order([sale, ShopifyFixture.transaction(REFUND, "REFUND", "25.00", "CASH")])
      run.with_endpoint { assert_equal 200, run.deliver("bad-currency") }

      assert_equal({ "status" => "retry" }, run.worker(success: false))
      assert_empty run.snapshot.fetch("transactions")
      assert_equal [0], run.snapshot.fetch("inbox").map(&:last)

      run.admin.order([sale, ShopifyFixture.transaction(REFUND, "REFUND", "25.00", "USDC")])
      run.read("UPDATE inbox SET next_attempt_at = 0 WHERE webhook_id = ?", ["bad-currency"])
      assert_equal({ "status" => "processed" }, run.worker)
      assert_equal [{ "currency" => "USDC", "collected" => "100.00", "refunded" => "25.00", "net" => "75.00" }],
                   run.summary.fetch("totals")
    end
  end

  def test_reconciliation_repairs_a_currency_accepted_before_validation
    ShopifyFixture.run do |run|
      assert_empty run.summary.fetch("totals")
      run.read("INSERT INTO transactions (shop, transaction_id, order_id, currency, kind, amount) " \
               "VALUES (?, ?, ?, ?, ?, ?)", [ALPHA, SALE, ORDER, "CASH", "SALE", "100.00"])
      stdout, stderr, status = run.command("bin/shopify-summary", ALPHA)
      refute status.success?
      assert_empty stdout
      assert_match(/currency/, stderr)
      assert_empty run.summary(BETA).fetch("totals")

      run.admin.page([ORDER])
      run.admin.order([ShopifyFixture.transaction(SALE, "SALE", "100.00")])
      run.reconcile
      assert_equal [{ "currency" => "CAD", "collected" => "100.00", "refunded" => "0.00", "net" => "100.00" }],
                   run.summary.fetch("totals")
      assert_equal [[SALE, "CAD"]], run.read("SELECT transaction_id, currency FROM transactions")

      run.admin.order([ShopifyFixture.transaction(SALE, "SALE", "100.00", "USD")])
      failure = run.reconcile(success: false)
      assert_match(/conflict/, failure.fetch("stderr"))
      assert_equal [[SALE, "CAD"]], run.read("SELECT transaction_id, currency FROM transactions")
    end
  end
end
