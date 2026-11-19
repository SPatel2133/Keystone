require "minitest/autorun"
require_relative "../../lib/event_consumer/bundle"
require_relative "../../lib/shopify_ledger/backup"
require_relative "../../lib/shopify_ledger/config"
require_relative "../support/shopify_scenarios"

class ShopifyBackupTest < Minitest::Test
  include ShopifyFixture

  def test_backup_refuses_a_missing_live_ledger
    ShopifyFixture.run do |run|
      destination = File.join(File.dirname(run.database), "missing-source.sqlite3")
      stdout, stderr, status = run.command("bin/shopify-backup", destination)

      assert_equal 1, status.exitstatus
      assert_empty stdout
      assert_includes stderr, "shopify ledger: backup refused: live database not found"
      refute File.exist?(run.database)
      refute File.exist?(destination)
    end
  end

  def test_backup_does_not_replace_a_destination_created_during_copy
    ShopifyFixture.run do |run|
      run.summary
      backup = ShopifyLedger::Backup.new(config_for(run))
      destination = File.join(File.dirname(run.database), "raced.sqlite3")
      verify = backup.method(:verify)
      backup.stub(:verify, ->(path) { File.write(destination, "racer"); verify.call(path) }) do
        error = assert_raises(ShopifyLedger::Backup::Refused) { backup.create(destination) }
        assert_equal "destination already exists", error.message
      end
      assert_equal "racer", File.read(destination)
      assert_empty Dir[File.join(File.dirname(run.database), "*.partial-*")]
    end
  end

  def test_backup_preserves_source_permissions
    ShopifyFixture.run do |run|
      run.summary
      File.chmod(0o600, run.database)
      backup = ShopifyLedger::Backup.new(config_for(run))
      destination = File.join(File.dirname(run.database), "private.sqlite3")
      previous_umask = File.umask(0o022)
      begin
        backup.create(destination)
      ensure
        File.umask(previous_umask)
      end

      assert_equal 0o600, File.stat(destination).mode & 0o777
    end
  end

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

  private

  def config_for(run)
    previous_http_setting = ENV["SHOPIFY_LEDGER_ALLOW_HTTP_LOOPBACK"]
    ENV["SHOPIFY_LEDGER_ALLOW_HTTP_LOOPBACK"] = "1"
    path = run.instance_variable_get(:@config_path)
    ShopifyLedger::Config.new(JSON.parse(File.read(path)), File.dirname(path))
  ensure
    previous_http_setting ? ENV["SHOPIFY_LEDGER_ALLOW_HTTP_LOOPBACK"] = previous_http_setting : ENV.delete("SHOPIFY_LEDGER_ALLOW_HTTP_LOOPBACK")
  end
end
