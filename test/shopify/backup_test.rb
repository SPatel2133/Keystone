require "minitest/autorun"
require_relative "../../lib/event_consumer/bundle"
require_relative "../support/shopify_scenarios"

class ShopifyBackupTest < Minitest::Test
  include ShopifyFixture

  def test_online_backup_under_concurrent_workers_is_a_consistent_snapshot
    ShopifyFixture.run do |run|
      run.with_endpoint do
        60.times do |index|
          number = 1000 + index
          order = "gid://shopify/Order/#{number}"
          run.admin.order([ShopifyFixture.transaction("gid://shopify/OrderTransaction/#{number}", "SALE", "1.00")], id: order)
          assert_equal 200, run.deliver("b-#{number}", payload: { id: number, admin_graphql_api_id: order })
        end
      end
      workers = Array.new(3) { run.spawn("bin/shopify-worker", "--drain") }
      backups = Array.new(3) { |index| run.json("bin/shopify-backup", "copy #{index}.sqlite3") }
      workers.each { |stdin, stdout, stderr, waiter| stdin.close; stdout.read; stderr.read; assert waiter.value.success? }

      backups.each do |report|
        assert_equal "ok", report.fetch("integrity")
        assert_equal 60, report.fetch("deliveries")
        db = SQLite3::Database.new(report.fetch("backup"), readonly: true)
        processed = db.get_first_value("SELECT COUNT(*) FROM inbox WHERE processed = 1")
        # Payments and their inbox completion commit together, so every snapshot agrees.
        assert_equal processed, db.get_first_value("SELECT COUNT(*) FROM transactions")
        assert_equal processed, report.fetch("transactions")
        db.close
      end
      assert_equal "60.00", run.summary.fetch("totals").first.fetch("net")
    end
  end

  def test_backup_refuses_to_overwrite_and_leaves_no_partial_file
    ShopifyFixture.run do |run|
      assert_empty run.summary.fetch("totals")
      first = run.json("bin/shopify-backup", "copy.sqlite3")
      assert_equal({ ALPHA => [], BETA => [] }, first.fetch("totals"))
      stdout, stderr, process = run.command("bin/shopify-backup", "copy.sqlite3")
      assert_equal 1, process.exitstatus
      assert_empty stdout
      assert_match(/already exists/, stderr)
      _stdout, stderr, process = run.command("bin/shopify-backup")
      assert_equal 1, process.exitstatus
      assert_match(/usage/, stderr)
      assert_empty Dir[File.join(File.dirname(first.fetch("backup")), "*.partial-*")]
    end
  end
end
