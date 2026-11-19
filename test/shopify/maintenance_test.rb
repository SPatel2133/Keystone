require "minitest/autorun"
require_relative "../../lib/event_consumer/bundle"
require_relative "../support/shopify_scenarios"

class ShopifyMaintenanceTest < Minitest::Test
  include ShopifyFixture

  def test_maintenance_vacuums_without_changing_totals_and_refuses_a_busy_writer
    ShopifyFixture.run do |run|
      run.admin.order([ShopifyScenarios.sale])
      run.with_endpoint { assert_equal 200, run.deliver("sale") }
      run.worker
      report = run.json("bin/shopify-maintain")
      assert_equal "100.00", report.fetch("totals").fetch(ALPHA).first.fetch("net")
      assert_equal 0, report.fetch("after").fetch("free_pages")
      assert_equal "100.00", run.summary.fetch("totals").first.fetch("net")

      path = run.read("PRAGMA database_list").first.last
      writer = SQLite3::Database.new(path)
      writer.execute("BEGIN IMMEDIATE")
      stdout, stderr, process = run.command("bin/shopify-maintain")
      writer.rollback
      writer.close
      assert_equal 1, process.exitstatus
      assert_empty stdout
      assert_match(/busy/, stderr)
      assert_equal 1, run.command("bin/shopify-maintain", "extra").last.exitstatus
    end
  end
end
