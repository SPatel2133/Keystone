require "minitest/autorun"
require_relative "../../lib/event_consumer/bundle"
require_relative "../../lib/shopify_ledger/config"
require_relative "../../lib/shopify_ledger/move_shop"
require_relative "../../lib/shopify_ledger/reconciliation"
require_relative "../support/shopify_fixture"

class ShopifyShopRoutingTest < Minitest::Test
  include ShopifyFixture

  def setup
    @previous_allow_http_loopback = ENV["SHOPIFY_LEDGER_ALLOW_HTTP_LOOPBACK"]
    ENV["SHOPIFY_LEDGER_ALLOW_HTTP_LOOPBACK"] = "1"
  end

  def teardown
    if @previous_allow_http_loopback
      ENV["SHOPIFY_LEDGER_ALLOW_HTTP_LOOPBACK"] = @previous_allow_http_loopback
    else
      ENV.delete("SHOPIFY_LEDGER_ALLOW_HTTP_LOOPBACK")
    end
  end

  def route(run, routes = {})
    path = File.join(File.dirname(run.database), "config.json")
    data = JSON.parse(File.read(path))
    data["databases"] = { "main" => File.basename(run.database), "eu" => "eu.sqlite3" }
    routes.each { |shop, name| data["shops"][shop]["database"] = name }
    File.write(path, JSON.generate(data))
    File.join(File.dirname(run.database), "eu.sqlite3")
  end

  def config(run) = JSON.parse(File.read(File.join(File.dirname(run.database), "config.json")))

  def loaded_config(path)
    previous = ENV["SHOPIFY_LEDGER_CONFIG"]
    ENV["SHOPIFY_LEDGER_CONFIG"] = path
    ShopifyLedger::Config.load
  ensure
    previous ? ENV["SHOPIFY_LEDGER_CONFIG"] = previous : ENV.delete("SHOPIFY_LEDGER_CONFIG")
  end

  def read(path, sql)
    SQLite3::Database.new(path) { |db| return db.execute(sql) }
  end

  def with_database(name)
    ENV["SHOPIFY_LEDGER_DATABASE"] = name
    yield
  ensure
    ENV.delete("SHOPIFY_LEDGER_DATABASE")
  end

  def move(run, shop = ALPHA, seam: nil)
    run.command(seam ? "test/support/shopify-move-shop-with-hooks" : "bin/shopify-move-shop", shop, "--to", "eu", seam: seam)
  end

  # A processed sale, a completed reconciliation and one pending delivery.
  def seed(run)
    run.admin.order([ShopifyFixture.transaction(SALE, "SALE", "100.00")])
    run.admin.page([ORDER])
    run.with_endpoint { assert_equal 200, run.deliver("sale") }
    assert_equal({ "status" => "processed" }, run.worker)
    run.reconcile
    run.with_endpoint { assert_equal 200, run.deliver("later") }
  end

  def counts(path, shop = ALPHA)
    %w[inbox transactions payment_events checkpoints reconciliation_runs].map do |table|
      read(path, "SELECT COUNT(*) FROM #{table} WHERE shop = '#{shop}'").first.first
    end
  end

  def test_each_shop_lives_in_its_routed_database
    ShopifyFixture.run do |run|
      eu = route(run, BETA => "eu")
      run.admin.order([ShopifyFixture.transaction(SALE, "SALE", "100.00")])
      run.admin.order([ShopifyFixture.transaction(SALE, "SALE", "7.00", "USD")], shop: BETA)
      run.with_endpoint do
        assert_equal 200, run.deliver("a", shop: ALPHA)
        assert_equal 200, run.deliver("b", shop: BETA)
      end
      assert_equal [[ALPHA]], read(run.database, "SELECT shop FROM inbox")
      assert_equal [[BETA]], read(eu, "SELECT shop FROM inbox")
      assert_equal({ "status" => "processed" }, run.worker)
      assert_equal({ "status" => "idle" }, run.worker)
      with_database("eu") { assert_equal({ "status" => "processed" }, run.worker) }
      assert_equal "100.00", run.summary(ALPHA).fetch("totals").first.fetch("net")
      assert_equal "7.00", run.summary(BETA).fetch("totals").first.fetch("net")
      with_database("eu") do
        backup = run.json("bin/shopify-backup", File.join(File.dirname(run.database), "eu-backup.sqlite3"))
        assert_equal [BETA], backup.fetch("totals").keys
        assert_equal 1, backup.fetch("transactions")
        assert_equal({ BETA => [{ "currency" => "USD", "collected" => "7.00", "refunded" => "0.00", "net" => "7.00" }] },
                     run.json("bin/shopify-maintain").fetch("totals"))
      end
      assert_equal [ALPHA], run.json("bin/shopify-maintain").fetch("totals").keys
      status = run.json("bin/shopify-status", success: false).fetch("shops").to_h { |shop| [shop["shop"], shop["transactions"]["total"]] }
      assert_equal({ ALPHA => 1, BETA => 1 }, status)
    end
  end

  def test_move_copies_verifies_switches_and_cleans_up
    ShopifyFixture.run do |run|
      seed(run)
      eu = route(run)
      before = counts(run.database)
      stdout, stderr, status = move(run)
      assert status.success?, stderr
      report = JSON.parse(stdout)
      assert_equal 2, report.fetch("copied").fetch("inbox")
      assert_equal "100.00", report.fetch("totals").first.fetch("net")
      assert_equal "eu", config(run).fetch("shops").fetch(ALPHA).fetch("database")
      assert_equal before, counts(eu)
      assert_equal [0, 0, 0, 0, 0], counts(run.database)

      with_database("eu") { assert_equal({ "status" => "processed" }, run.worker) }
      assert_equal "100.00", run.summary.fetch("totals").first.fetch("net")
      assert_equal [[2, 2]], read(eu, "SELECT SUM(processed), COUNT(*) FROM inbox")
      assert_equal [[1]], read(eu, "SELECT COUNT(*) FROM transactions")
      refute_nil run.reconcile
    end
  end

  def test_crash_after_copy_keeps_the_old_route_and_a_rerun_finishes
    ShopifyFixture.run do |run|
      seed(run)
      eu = route(run)
      before = counts(run.database)
      _stdout, _stderr, status = move(run, seam: "after_copy")
      assert_equal 9, status.termsig
      assert_nil config(run).fetch("shops").fetch(ALPHA)["database"]
      assert_equal before, counts(run.database)
      assert_equal "100.00", run.summary.fetch("totals").first.fetch("net")

      _stdout, stderr, status = move(run)
      assert status.success?, stderr
      assert_equal before, counts(eu)
      assert_equal [0, 0, 0, 0, 0], counts(run.database)
    end
  end

  def test_crash_after_switch_is_finished_by_a_rerun_that_only_cleans_up
    ShopifyFixture.run do |run|
      seed(run)
      eu = route(run)
      before = counts(run.database)
      _stdout, _stderr, status = move(run, seam: "after_switch")
      assert_equal 9, status.termsig
      assert_equal "eu", config(run).fetch("shops").fetch(ALPHA).fetch("database")
      assert_equal before, counts(run.database), "the old copy stays until cleanup"
      assert_equal "100.00", run.summary.fetch("totals").first.fetch("net")

      stdout, stderr, status = move(run)
      assert status.success?, stderr
      assert_nil JSON.parse(stdout)["copied"]
      assert_equal before, counts(eu)
      assert_equal [0, 0, 0, 0, 0], counts(run.database)
    end
  end

  # Found by fuzzer: an orphan copy left by a crash after the copy goes stale as
  # the shop keeps working on its old route. Cleanup refused it forever, although
  # deleting it loses nothing.
  def test_cleanup_deletes_a_stale_orphan_copy_left_by_a_crash_after_copy
    ShopifyFixture.run do |run|
      seed(run)
      eu = route(run)
      _stdout, _stderr, status = move(run, seam: "after_copy")
      assert_equal 9, status.termsig
      assert_equal({ "status" => "processed" }, run.worker)
      before = counts(run.database)
      _stdout, stderr, status = run.command("bin/shopify-move-shop", ALPHA, "--to", "main")
      assert status.success?, stderr
      assert_equal [0, 0, 0, 0, 0], counts(eu)
      assert_equal before, counts(run.database)
      assert_equal "100.00", run.summary.fetch("totals").first.fetch("net")
    end
  end

  # Found by fuzzer: after a crash between switch and cleanup, a worker draining
  # the old database processed the stale copy's pending delivery and recorded a
  # payment there, which then blocked cleanup.
  def test_a_worker_skips_deliveries_of_shops_routed_to_another_database
    ShopifyFixture.run do |run|
      seed(run)
      eu = route(run)
      _stdout, _stderr, status = move(run, seam: "after_switch")
      assert_equal 9, status.termsig
      run.admin.order([ShopifyFixture.transaction(SALE, "SALE", "100.00"), ShopifyFixture.transaction(REFUND, "REFUND", "25.00")])
      assert_equal({ "status" => "idle" }, run.worker)
      assert_equal [[1]], read(run.database, "SELECT COUNT(*) FROM transactions")
      _stdout, stderr, status = move(run)
      assert status.success?, stderr
      with_database("eu") { assert_equal({ "status" => "processed" }, run.worker) }
      assert_equal "75.00", run.summary.fetch("totals").first.fetch("net")
      assert_equal [0, 0, 0, 0, 0], counts(run.database)
      assert_equal [[2]], read(eu, "SELECT COUNT(*) FROM transactions")
    end
  end

  def test_cleanup_refuses_when_the_old_database_received_new_rows
    ShopifyFixture.run do |run|
      seed(run)
      route(run)
      move(run, seam: "after_switch")
      # A webhook process still holding the old route wrote here after the copy.
      SQLite3::Database.new(run.database) do |db|
        db.execute("INSERT INTO inbox (shop, webhook_id, topic, order_id, received_at) VALUES (?, 'stray', 'orders/updated', ?, 0)",
                   [ALPHA, ORDER])
      end
      _stdout, stderr, status = move(run)
      refute status.success?
      assert_match(/1 inbox rows for #{Regexp.escape(ALPHA)} that the routed copy lacks/, stderr)
      assert_equal 3, read(run.database, "SELECT COUNT(*) FROM inbox").first.first
    end
  end

  def test_rejects_unknown_databases_and_bad_usage
    ShopifyFixture.run do |run|
      route(run)
      _stdout, stderr, status = run.command("bin/shopify-move-shop", ALPHA, "--to", "mars")
      assert_equal 1, status.exitstatus
      assert_match(/unknown database "mars"/, stderr)
      _stdout, _stderr, status = run.command("bin/shopify-move-shop", ALPHA)
      assert_equal 64, status.exitstatus
      path = File.join(File.dirname(run.database), "config.json")
      data = JSON.parse(File.read(path))
      data["shops"][ALPHA]["database"] = "mars"
      File.write(path, JSON.generate(data))
      _stdout, stderr, status = run.command("bin/shopify-summary", ALPHA)
      refute status.success?
      assert_match(/unknown database/, stderr)
    end
  end

  def test_reconciliation_uses_the_new_route_from_a_pre_move_config_object
    ShopifyFixture.run do |run|
      run.summary
      eu = route(run)
      config_path = File.join(File.dirname(run.database), "config.json")
      old_config = loaded_config(config_path)
      repair_order = "gid://shopify/Order/103"
      run.admin.order([ShopifyFixture.transaction("gid://shopify/OrderTransaction/303", "SALE", "15.00")],
                      id: repair_order)
      run.admin.page([repair_order])

      assert_equal 0, ShopifyLedger::MoveShop.run(config_path, ALPHA, "eu").fetch(:copied).fetch("inbox")
      refute_nil ShopifyLedger::Reconciliation.new(old_config).run(ALPHA)
      assert_equal [[1]], read(eu, "SELECT COUNT(*) FROM transactions WHERE order_id = '#{repair_order}'")
      assert_equal [[0]], read(run.database, "SELECT COUNT(*) FROM transactions WHERE order_id = '#{repair_order}'")
    end
  end

  def test_move_waits_for_a_shared_reconciliation_lock
    ShopifyFixture.run do |run|
      run.summary
      route(run)
      config_path = File.join(File.dirname(run.database), "config.json")
      lock_path = "#{config_path}.lock"
      File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_SH)
        move_thread = Thread.new { ShopifyLedger::MoveShop.run(config_path, ALPHA, "eu") }
        begin
          assert_nil move_thread.join(0.2)
        ensure
          lock.flock(File::LOCK_UN)
        end
        assert move_thread.value
      end
    end
  end

  def test_concurrent_moves_serialize_and_preserve_the_second_destination
    ShopifyFixture.run do |run|
      seed(run)
      eu = route(run)
      config_path = File.join(File.dirname(run.database), "config.json")
      data = config(run)
      data["databases"]["us"] = "us.sqlite3"
      File.write(config_path, JSON.generate(data))
      us = File.join(File.dirname(run.database), "us.sqlite3")
      before = counts(run.database)
      copied = Queue.new
      continue = Queue.new
      first = Thread.new do
        ShopifyLedger::MoveShop.run(config_path, ALPHA, "eu", after_copy: -> { copied << true; continue.pop })
      end
      copied.pop
      second_started = Queue.new
      second = Thread.new do
        second_started << true
        ShopifyLedger::MoveShop.run(config_path, ALPHA, "us")
      end
      second_started.pop
      sleep 0.1
      continue << true
      first.value
      second.value

      assert_equal "us", config(run).fetch("shops").fetch(ALPHA).fetch("database")
      assert_equal before, counts(us)
      assert_equal [0, 0, 0, 0, 0], counts(run.database)
      assert_equal [0, 0, 0, 0, 0], counts(eu)
    end
  end

  def test_move_back_refuses_to_delete_rows_preserved_by_cleanup
    ShopifyFixture.run do |run|
      seed(run)
      route(run)
      config_path = File.join(File.dirname(run.database), "config.json")
      ShopifyLedger::MoveShop.run(config_path, ALPHA, "eu")
      SQLite3::Database.new(run.database) do |db|
        db.execute("INSERT INTO inbox (shop, webhook_id, topic, order_id, received_at) VALUES (?, ?, ?, ?, ?)",
                   [ALPHA, "preserved", "orders/updated", ORDER, 0])
      end

      error = assert_raises(ShopifyLedger::MoveShop::Refused) do
        ShopifyLedger::MoveShop.run(config_path, ALPHA, "main")
      end
      assert_match(/has 1 inbox rows for #{Regexp.escape(ALPHA)} that the source lacks; reconcile them by hand/, error.message)
      assert_equal 1, read(run.database, "SELECT COUNT(*) FROM inbox WHERE webhook_id = 'preserved'").first.first
    end
  end

  def test_move_preserves_config_permissions
    ShopifyFixture.run do |run|
      seed(run)
      route(run)
      config_path = File.join(File.dirname(run.database), "config.json")
      File.chmod(0o640, config_path)

      assert_equal 0, move(run).last.exitstatus
      assert_equal 0o640, File.stat(config_path).mode & 0o7777
    end
  end

  def test_move_keeps_temporary_config_private_during_chown
    ShopifyFixture.run do |run|
      route(run)
      config_path = File.join(File.dirname(run.database), "config.json")
      File.chmod(0o640, config_path)
      temporary_mode = nil

      File.stub(:chown, ->(_uid, _gid, temporary) { temporary_mode = File.stat(temporary).mode & 0o7777 }) do
        ShopifyLedger::MoveShop.switch(config_path, ALPHA, "eu")
      end

      assert_equal 0o600, temporary_mode
      assert_equal 0o640, File.stat(config_path).mode & 0o7777
    end
  end

  def test_reconciliation_succeeds_with_read_only_config_directory
    skip "read-only directory test requires a non-root user" if Process.uid.zero?

    ShopifyFixture.run do |run|
      run.summary
      run.admin.order([ShopifyFixture.transaction(SALE, "SALE", "100.00")])
      run.admin.page([ORDER])
      config_directory = File.join(File.dirname(run.database), "readonly-config")
      Dir.mkdir(config_directory)
      config_path = File.join(config_directory, "config.json")
      data = JSON.parse(File.read(File.join(File.dirname(run.database), "config.json")))
      data["database"] = run.database
      File.write(config_path, JSON.generate(data))
      config = loaded_config(config_path)
      lock_path = "#{config_path}.lock"
      File.write(lock_path, "")
      File.chmod(0o444, lock_path)
      original_mode = File.stat(config_directory).mode & 0o7777
      File.chmod(0o555, config_directory)

      begin
        refute_nil ShopifyLedger::Reconciliation.new(config).run(ALPHA)

        File.chmod(original_mode, config_directory)
        File.unlink(lock_path)
        File.chmod(0o555, config_directory)
        refute_nil ShopifyLedger::Reconciliation.new(config).run(ALPHA)
      ensure
        File.chmod(original_mode, config_directory)
      end
    end
  end

  def test_reconciliation_rejects_route_change_during_unlocked_read_only_run
    skip "read-only directory test requires a non-root user" if Process.uid.zero?

    ShopifyFixture.run do |run|
      run.summary
      eu = route(run)
      config_directory = File.join(File.dirname(run.database), "readonly-route-config")
      Dir.mkdir(config_directory)
      config_path = File.join(config_directory, "config.json")
      data = JSON.parse(File.read(File.join(File.dirname(run.database), "config.json")))
      data["database"] = run.database
      data["databases"] = { "main" => run.database, "eu" => eu }
      data["shops"][ALPHA]["database"] = "main"
      File.write(config_path, JSON.generate(data))
      config = loaded_config(config_path)
      lock_path = "#{config_path}.lock"
      refute File.exist?(lock_path)
      original_mode = File.stat(config_directory).mode & 0o7777
      File.chmod(0o555, config_directory)

      begin
        run.admin.order([ShopifyFixture.transaction(SALE, "SALE", "100.00")])
        run.admin.arrange(ALPHA, "ReconcileOrders", nil,
                          { data: { orders: { nodes: [{ id: ORDER }], pageInfo: { hasNextPage: false, endCursor: nil } } } }) do
          changed = JSON.parse(File.read(config_path))
          changed["shops"][ALPHA]["database"] = "eu"
          File.write(config_path, JSON.generate(changed))
        end

        error = assert_raises(ShopifyLedger::Admin::Error) do
          ShopifyLedger::Reconciliation.new(config).run(ALPHA)
        end
        assert_equal "shop moved to another database during reconciliation; rerun reconcile", error.message
      ensure
        File.chmod(original_mode, config_directory)
      end
    end
  end
end
