require "minitest/autorun"
require_relative "../../lib/event_consumer/bundle"
require_relative "../../lib/shopify_ledger/reconciliation"
require_relative "../support/shopify_scenarios"

class ShopifyResumableReconciliationTest < Minitest::Test
  include ShopifyFixture

  THIRD_ORDER = "gid://shopify/Order/103".freeze
  OUTAGE = { errors: [{ message: "synthetic page outage" }] }.freeze

  def arrange_three_pages(run)
    run.admin.page([ORDER], next_cursor: "page-2")
    run.admin.page([OTHER_ORDER], after: "page-2", next_cursor: "page-3")
    run.admin.page([THIRD_ORDER], after: "page-3")
    run.admin.order([ShopifyScenarios.sale])
    run.admin.order([ShopifyScenarios.refund], id: OTHER_ORDER)
    run.admin.order([ShopifyFixture.transaction("gid://shopify/OrderTransaction/303", "SALE", "7.50")], id: THIRD_ORDER)
  end

  def cursors(run)
    run.admin.requests.select { |r| r["operation"] == "ReconcileOrders" }.map { |r| r.fetch("variables")["after"] }
  end

  def runs(run)
    run.read("SELECT status, pages, orders, cursor, attempts FROM reconciliation_runs ORDER BY id")
  end

  def test_failed_run_resumes_at_first_unapplied_page_and_reports_progress
    ShopifyFixture.run do |run|
      arrange_three_pages(run)
      run.admin.arrange(ALPHA, "ReconcileOrders", "page-3", OUTAGE, code: 503)
      failure = run.reconcile(success: false)
      assert_match(/HTTP 503/, failure.fetch("stderr"))
      assert_equal [["failed", 2, 2, "page-3", 1]], runs(run)
      assert_empty run.snapshot.fetch("checkpoints")
      assert_equal [["delivery_source", "reconciliation:1"]] * 2,
                   run.read("SELECT 'delivery_source', source FROM transactions")

      run.admin.page([THIRD_ORDER], after: "page-3")
      result = run.reconcile
      # Pages one and two are not fetched again for the failed window.
      assert_equal [nil, "page-2", "page-3", "page-3", nil, "page-2", "page-3"], cursors(run)
      assert_equal [["completed", 3, 3, nil, 2], ["completed", 3, 3, nil, 1]], runs(run)
      assert_equal [[ALPHA, result.fetch("synced_through")]], run.snapshot.fetch("checkpoints")
      assert_equal [{ "currency" => "CAD", "collected" => "107.50", "refunded" => "25.00", "net" => "82.50" }],
                   run.summary.fetch("totals")
      assert_equal [["reconciliation:1"]] * 3, run.read("SELECT source FROM transactions")
    end
  end

  def test_cursor_that_fails_on_reuse_restarts_the_window_from_page_one
    ShopifyFixture.run do |run|
      arrange_three_pages(run)
      run.admin.arrange(ALPHA, "ReconcileOrders", "page-3", OUTAGE, code: 503)
      run.reconcile(success: false)
      # The saved cursor is rejected again on resume, as an expired cursor would be.
      run.reconcile(success: false)
      assert_equal [["failed", 0, 2, nil, 2]], runs(run)

      run.admin.page([THIRD_ORDER], after: "page-3")
      run.reconcile
      assert_equal [nil, "page-2", "page-3", "page-3", nil, "page-2", "page-3", nil, "page-2", "page-3"], cursors(run)
      assert_equal "82.50", run.summary.fetch("totals").first.fetch("net")
    end
  end

  def test_resume_failure_preserves_progress_advanced_by_another_reconciler
    ShopifyFixture.run do |run|
      arrange_three_pages(run)
      run.admin.arrange(ALPHA, "ReconcileOrders", "page-3", OUTAGE, code: 503)
      run.reconcile(success: false)
      advanced = false
      run.admin.arrange(ALPHA, "ReconcileOrders", "page-3", OUTAGE, code: 503) do
        unless advanced
          advanced = true
          run.read("UPDATE reconciliation_runs SET pages = 3, cursor = ? WHERE id = 1", ["page-4"])
        end
      end

      run.reconcile(success: false)

      assert_equal [["failed", 3, "page-4"]], run.read("SELECT status, pages, cursor FROM reconciliation_runs")
    end
  end

  def test_killed_reconciler_leaves_a_running_window_that_the_next_run_resumes
    ShopifyFixture.run do |run|
      arrange_three_pages(run)
      reached = Queue.new
      release = Queue.new
      run.admin.arrange(ALPHA, "ReconcileOrders", "page-3",
                        { data: { orders: { nodes: [{ id: THIRD_ORDER }], pageInfo: { hasNextPage: false, endCursor: nil } } } }) do
        reached << true
        release.pop
      end
      stdin, stdout, stderr, waiter = run.spawn("bin/reconcile", ALPHA)
      begin
        stdin.close
        Timeout.timeout(15) { reached.pop }
        Process.kill("KILL", waiter.pid)
        refute waiter.value.success?
      ensure
        release << true
        [stdout, stderr].each(&:close)
      end
      assert_equal [["running", 2, 2, "page-3", 1]], runs(run)

      run.admin.page([THIRD_ORDER], after: "page-3")
      run.reconcile
      assert_equal "page-3", cursors(run)[3]
      assert_equal [["completed", 3, 3, nil, 2], ["completed", 3, 3, nil, 1]], runs(run)
      assert_equal "82.50", run.summary.fetch("totals").first.fetch("net")
    end
  end

  def test_final_page_progress_resumes_without_refetching_orders
    ShopifyFixture.run do |run|
      run.admin.page([])
      config = config_for(run)
      reconciliation = ShopifyLedger::Reconciliation.new(config)
      save_progress = reconciliation.method(:save_progress)
      reconciliation.stub(:save_progress, lambda { |*arguments|
        save_progress.call(*arguments)
        raise "interrupted after page progress"
      }) do
        assert_raises(RuntimeError) { reconciliation.run(ALPHA) }
      end
      assert_equal [["failed", 1, nil]], run.read("SELECT status, pages, cursor FROM reconciliation_runs")

      requests_before_resume = run.admin.requests.count { |request| request["operation"] == "ReconcileOrders" }
      resumed = reconciliation.send(:open_run, ALPHA)
      checkpoint = reconciliation.send(:finish, ShopifyLedger::Admin.new(config, ALPHA), ALPHA, resumed)

      assert_equal requests_before_resume,
                   run.admin.requests.count { |request| request["operation"] == "ReconcileOrders" }
      assert_equal [["completed", 1, nil]], run.read("SELECT status, pages, cursor FROM reconciliation_runs")
      assert_equal [[ALPHA, checkpoint]], run.snapshot.fetch("checkpoints")
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
