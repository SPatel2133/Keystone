require "minitest/autorun"
require_relative "../../lib/event_consumer/bundle"
require_relative "../support/shopify_scenarios"

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
end
