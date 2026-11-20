require "minitest/autorun"
require "delegate"
require_relative "../../lib/event_consumer/bundle"
require_relative "../../lib/shopify_ledger/deliveries"
require_relative "../../lib/shopify_ledger/storage"
require_relative "../support/shopify_scenarios"

class StaleProcessedDatabase < SimpleDelegator
  def get_first_row(statement, parameters = [])
    row = super
    if !@stale_read && statement.include?("FROM inbox") && row
      @stale_read = true
      row = row.dup
      row[4] = 0
    end
    row
  end
end

class StaleProcessedStore
  def initialize(path)
    @path = path
  end

  def connect
    SQLite3::Database.new(@path) do |db|
      yield StaleProcessedDatabase.new(db)
    end
  end

  def transaction(db, &block)
    ShopifyLedger::Storage.transaction(db, &block)
  end
end

class ShopifyOperationsRaceTest < Minitest::Test
  include ShopifyFixture

  OUTAGE = { errors: [{ message: "synthetic outage" }] }.freeze

  def test_second_reconciler_finishes_a_window_while_the_first_is_mid_fetch
    ShopifyFixture.run do |run|
      run.admin.page([ORDER], next_cursor: "page-2")
      run.admin.order([ShopifyScenarios.sale])
      run.admin.order([ShopifyScenarios.refund], id: OTHER_ORDER)
      second = nil
      started = false
      page_two = { data: { orders: { nodes: [{ id: OTHER_ORDER }], pageInfo: { hasNextPage: false, endCursor: nil } } } }
      run.admin.arrange(ALPHA, "ReconcileOrders", "page-2", page_two) do
        # The first reconciler is waiting on page 2. Another process resumes the
        # same open window, finishes it and scans a fresh window before it returns.
        unless started
          started = true
          second = run.reconcile
        end
      end
      first = run.reconcile
      assert_equal ShopifyScenarios::AFTER, run.summary
      assert_equal 2, run.read("SELECT COUNT(*) FROM transactions").first.first
      assert_equal [["completed"], ["completed"]], run.read("SELECT status FROM reconciliation_runs ORDER BY id")
      # The checkpoint never moves backwards when the slower process finishes last.
      assert_equal [[ALPHA, second.fetch("synced_through")]], run.snapshot.fetch("checkpoints")
      assert_operator first.fetch("synced_through"), :<=, second.fetch("synced_through")
      assert_equal 0, run.read("SELECT COUNT(*) FROM reconciliation_runs WHERE status <> 'completed'").first.first
    end
  end

  def test_operator_retry_during_a_failing_fetch_is_not_overwritten_by_the_worker
    ShopifyFixture.run do |run|
      run.configure(max_attempts: 2)
      run.with_endpoint { assert_equal 200, run.deliver("flaky") }
      run.admin.arrange(ALPHA, "OrderPayments", ORDER, OUTAGE, code: 503)
      run.worker(success: false)
      run.read("UPDATE inbox SET next_attempt_at = 0")
      retried = false
      run.admin.arrange(ALPHA, "OrderPayments", ORDER, OUTAGE, code: 503) do
        unless retried
          retried = true
          run.json("bin/shopify-deliveries", "retry", ALPHA, "flaky")
        end
      end
      # Without the attempts guard this second failure would park the delivery
      # the operator just requeued.
      assert_equal({ "status" => "retry" }, run.worker(success: false))
      assert_equal [[0, nil, 1, 1]], run.read("SELECT processed, parked_at, attempts, requeues FROM inbox")
    end
  end

  def test_delivery_retry_refuses_a_row_that_became_processed_after_read
    ShopifyFixture.run do |run|
      run.with_endpoint { assert_equal 200, run.deliver("finished") }
      run.read("UPDATE inbox SET processed = 1 WHERE webhook_id = ?", ["finished"])
      deliveries = ShopifyLedger::Deliveries.new(nil, store: StaleProcessedStore.new(run.database))

      error = assert_raises(ShopifyLedger::Deliveries::Refused) { deliveries.retry(ALPHA, "finished") }
      assert_equal "delivery already processed", error.message
    end
  end
end
