require "minitest/autorun"
require "bigdecimal"
require_relative "../../lib/event_consumer/bundle"
require_relative "../support/shopify_scenarios"

class ShopifyAuditTest < Minitest::Test
  include ShopifyFixture

  def test_audit_traces_each_total_to_the_delivery_or_reconciliation_run_that_recorded_it
    ShopifyFixture.run do |run|
      run.admin.order([ShopifyScenarios.sale])
      run.with_endpoint do
        assert_equal 200, run.deliver("sale-notice")
        assert_equal 200, run.deliver("sale-retry")
      end
      run.worker
      run.worker
      # The refund's webhook was never delivered; reconciliation repairs it.
      run.admin.page([ORDER, OTHER_ORDER])
      run.admin.order([ShopifyScenarios.refund], id: OTHER_ORDER)
      run.admin.order([ShopifyScenarios.sale, ShopifyFixture.transaction("gid://shopify/OrderTransaction/9", "SALE", "0.10", "USD")])
      run.reconcile

      shop = run.json("bin/shopify-audit", ALPHA)
      assert_equal 3, shop.fetch("transaction_count")
      refute shop.fetch("truncated")
      origins = shop.fetch("transactions").to_h { |row| [row.fetch("transaction_id"), row.values_at("recorded_by", "reference")] }
      assert_equal({ ShopifyScenarios::SALE => %w[delivery sale-notice],
                     "gid://shopify/OrderTransaction/9" => %w[reconciliation 1],
                     ShopifyScenarios::REFUND => %w[reconciliation 1] }, origins)
      # Independent oracle: recompute every currency total from the listed rows.
      oracle = shop.fetch("transactions").group_by { |row| row["currency"] }.transform_values do |rows|
        rows.sum(BigDecimal("0")) { |row| BigDecimal(row["amount"]) * (row["kind"] == "REFUND" ? -1 : 1) }
      end
      assert_equal oracle, shop.fetch("totals").to_h { |total| [total["currency"], BigDecimal(total["net"])] }
      assert_equal run.summary.fetch("totals"), shop.fetch("totals")

      order = run.json("bin/shopify-audit", ALPHA, "--order", ORDER)
      assert_equal [%w[sale-notice processed], %w[sale-retry processed]],
                   order.fetch("deliveries").map { |d| d.values_at("webhook_id", "state") }
      assert_equal %w[CAD USD], order.fetch("totals").map { |t| t["currency"] }
      assert_equal "100.00", order.fetch("totals").first.fetch("net")

      repaired = run.json("bin/shopify-audit", ALPHA, "--order", OTHER_ORDER)
      assert_empty repaired.fetch("deliveries")
      assert_equal [{ "currency" => "CAD", "collected" => "0.00", "refunded" => "25.00", "net" => "-25.00" }], repaired.fetch("totals")

      limited = run.json("bin/shopify-audit", ALPHA, "--limit", "1")
      assert limited.fetch("truncated")
      assert_equal 1, limited.fetch("transactions").size
      assert_empty run.json("bin/shopify-audit", BETA).fetch("transactions")

      [[], [ALPHA, "--order"], [ALPHA, "--limit", "0"], [ALPHA, "--limit", "x"], [ALPHA, "--since", "1"],
       ["unknown.myshopify.com"]].each do |arguments|
        stdout, stderr, status = run.command("bin/shopify-audit", *arguments)
        refute status.success?, arguments.inspect
        assert_empty stdout
        assert_match(/ArgumentError/, stderr)
      end
    end
  end
end
