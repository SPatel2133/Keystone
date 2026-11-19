require "minitest/autorun"
require_relative "../../lib/event_consumer/bundle"
require_relative "../support/shopify_scenarios"

class ShopifyFleetTest < Minitest::Test
  include ShopifyFixture

  def test_reconcile_all_isolates_a_failing_shop
    ShopifyFixture.run do |run|
      run.admin.page([ORDER])
      run.admin.order([ShopifyScenarios.sale])
      run.admin.arrange(BETA, "ReconcileOrders", nil, { errors: [{ message: "outage" }] }, code: 500)
      stdout, _stderr, process = run.command("bin/reconcile", "--all")
      assert_equal 1, process.exitstatus
      results = JSON.parse(stdout).fetch("shops")
      assert_equal [ALPHA, BETA], results.map { |result| result.fetch("shop") }
      assert results.first.key?("synced_through")
      assert_match(/HTTP 500/, results.last.fetch("error"))
      assert_equal [[ALPHA, "completed"], [BETA, "failed"]], run.read("SELECT shop, status FROM reconciliation_runs ORDER BY shop")
      assert_equal "100.00", run.summary.fetch("totals").first.fetch("net")

      run.admin.page([], shop: BETA)
      assert_equal 0, run.command("bin/reconcile", "--all").last.exitstatus
    end
  end

  def test_status_exposes_prometheus_counts_without_money
    ShopifyFixture.run do |run|
      run.admin.order([ShopifyScenarios.sale])
      run.with_endpoint { assert_equal 200, run.deliver("sale") }
      run.worker
      run.admin.page([])
      run.reconcile
      stdout, _stderr, process = run.command("bin/shopify-status", "--prometheus", ALPHA)
      assert_equal 0, process.exitstatus
      lines = stdout.lines.map(&:chomp)
      assert_includes lines, %(shopify_ledger_healthy{shop="#{ALPHA}"} 1)
      assert_includes lines, %(shopify_ledger_deliveries{shop="#{ALPHA}",state="processed"} 1)
      assert_includes lines, %(shopify_ledger_deliveries{shop="#{ALPHA}",state="parked"} 0)
      assert_includes lines, %(shopify_ledger_transactions{shop="#{ALPHA}",source="delivery"} 1)
      assert_includes lines, %(shopify_ledger_reconciliation_open_run{shop="#{ALPHA}"} 0)
      assert lines.grep(/\A[a-z_]+\{/).all? { |line| line.match?(/\A[a-z_]+\{[^}]*\} \d+\z/) }, stdout
      refute_match(/100\.00|net|collected/, stdout)
      refute_includes stdout, BETA

      everyone, _stderr, process = run.command("bin/shopify-status", "--prometheus")
      assert_equal 2, process.exitstatus
      assert_includes everyone, %(shopify_ledger_healthy{shop="#{BETA}"} 0)
      assert_equal 1, run.command("bin/shopify-status", "--prometheus", ALPHA, BETA).last.exitstatus
    end
  end
end
