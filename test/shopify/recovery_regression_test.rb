require "minitest/autorun"
require "minitest/mock"
require "tmpdir"
require_relative "../../lib/event_consumer/bundle"
require_relative "../../lib/shopify_ledger/reconciliation"
require_relative "../../lib/shopify_ledger/config"
require_relative "../support/shopify_fixture"

class ShopifyRecoveryRegressionTest < Minitest::Test
  SHOP = "alpha.myshopify.com"
  ORDER = "gid://shopify/Order/101"
  OLDER_ORDER = "gid://shopify/Order/100"

  class CorruptEncodingAdmin < ShopifyFixture::Admin
    private

    def respond(request, response)
      super
      response["Content-Encoding"] = "gzip" if response.body == "invalid gzip"
    end
  end

  def test_worker_defers_corrupt_http_delivery_and_processes_next
    admin = CorruptEncodingAdmin.new
    ShopifyFixture::Admin.stub(:new, admin) do
      ShopifyFixture.run do |run|
        run.admin.arrange(SHOP, "OrderPayments", ORDER, "invalid gzip")
        run.admin.order([], id: ShopifyFixture::OTHER_ORDER)
        run.with_endpoint do
          assert_equal 200, run.deliver("bad-compression")
          assert_equal 200, run.deliver("next-order", payload: { id: 102 })
        end
        assert_equal({ "status" => "retry" }, run.worker(success: false))
        assert_equal({ "status" => "processed" }, run.worker)
        assert_equal [[0, 1], [1, 0]], run.read("SELECT processed, attempts FROM inbox ORDER BY id")
        assert_empty run.snapshot.fetch("transactions")
      end
    end
  end

  def test_worker_drains_next_delivery_after_losing_selection_race
    ShopifyFixture.run do |run|
      run.with_endpoint do
        assert_equal 200, run.deliver("oldest")
        assert_equal 200, run.deliver("next", payload: { id: 102 })
      end
      run.admin.order([], id: ShopifyFixture::OTHER_ORDER)
      first_order = { id: ORDER, transactions: [], transactionsCount: { count: 0, precision: "EXACT" } }
      other_worker = nil
      run.admin.arrange(SHOP, "OrderPayments", ORDER, { data: { order: first_order } }) do
        # Once the first worker is waiting on HTTP, let a competing process
        # fetch and commit the same row before the first worker can resume.
        run.admin.order([])
        other_worker = run.worker
      end
      original_worker = run.worker
      assert_equal({ "status" => "processed" }, other_worker)
      assert_equal({ "status" => "processed" }, original_worker)
      assert_equal [[1], [1]], run.read("SELECT processed FROM inbox ORDER BY id")
      assert_equal({ "status" => "idle" }, run.worker)
    end
  end

  def test_failed_first_reconciliation_keeps_oldest_eligible_order_on_retry
    start = Time.utc(2026, 11, 19, 12)
    # This order is eligible on the failed page. It ages out of a fresh
    # seven-day window before the first successful run.
    refund_updated = start - (7 * 24 * 3600) + 5
    filters = []
    requests = 0
    admin = Object.new
    admin.define_singleton_method(:orders_page) do |filter, cursor|
      filters << filter
      requests += 1
      lower = Time.iso8601(filter.match(/updated_at:>='([^']+)'/)[1])
      if lower > refund_updated
        [[], nil]
      elsif !cursor
        [[OLDER_ORDER], "more"]
      elsif requests == 2
        raise ShopifyLedger::Admin::Error, "page two unavailable"
      else
        [[ORDER], nil]
      end
    end
    admin.define_singleton_method(:order_transactions) do |id|
      if id == OLDER_ORDER
        []
      else
        [{ "id" => "gid://shopify/OrderTransaction/202", "kind" => "REFUND", "status" => "SUCCESS",
           "amountSet" => { "shopMoney" => { "amount" => "25.00", "currencyCode" => "CAD" } } }]
      end
    end

    Dir.mktmpdir("shopify-initial-window-") do |dir|
      config = ShopifyLedger::Config.new({ "database" => "shop.sqlite3", "secret" => "test",
                                           "shops" => { SHOP => { "token" => "test" } } }, dir)
      storage = ShopifyLedger::Storage.new(config.database)
      ShopifyLedger::Admin.stub(:new, admin) do
        first = ShopifyLedger::Reconciliation.new(config, clock: -> { start })
        capture_io { assert_raises(ShopifyLedger::Admin::Error) { first.run(SHOP) } }
        assert_empty storage.connect { |db| db.execute("SELECT * FROM checkpoints") }

        later = start + 60
        restarted = ShopifyLedger::Reconciliation.new(config, clock: -> { later })
        capture_io { assert_equal later.iso8601, restarted.run(SHOP) }
      end
      assert_equal [["REFUND", "25.00"]], storage.connect { |db| db.execute("SELECT kind, amount FROM transactions") }
      # The retry resumes the failed first window at page two instead of a fresh window.
      assert_equal filters.first, filters[2]
    end
  end
end
