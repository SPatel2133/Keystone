require "minitest/autorun"
require_relative "../../lib/event_consumer/bundle"
require_relative "../support/shopify_scenarios"

class ShopifyLedgerTest < Minitest::Test
  include ShopifyFixture

  def test_before_commit
    evidence = ShopifyScenarios.worker_crash("before_commit")
    assert_equal 0, evidence.fetch("before_restart").fetch("inbox").last.last
    assert_equal [SALE], evidence.fetch("before_restart").fetch("transactions").map { |row| row[1] }
    assert_equal 9, evidence.fetch("child").fetch("signal")
    assert_equal [], evidence.fetch("child").fetch("stdout_bytes")
    assert_equal ShopifyScenarios::AFTER, evidence.fetch("summary")
  end

  def test_after_commit
    evidence = ShopifyScenarios.worker_crash("after_commit")
    assert_equal 1, evidence.fetch("before_restart").fetch("inbox").last.last
    assert_equal [SALE, REFUND], evidence.fetch("before_restart").fetch("transactions").map { |row| row[1] }
    assert_equal 9, evidence.fetch("child").fetch("signal")
    assert_equal [], evidence.fetch("child").fetch("stdout_bytes")
    assert_equal ShopifyScenarios::AFTER, evidence.fetch("summary")
  end

  def test_lost_webhook_ack
    evidence = ShopifyScenarios.lost_webhook_ack
    assert_equal 9, evidence.fetch("signal")
    assert_equal 200, evidence.fetch("retry_http_status")
  end

  def test_rejects_signatures_malformed_input_and_unknown_shop
    ShopifyFixture.run do |run|
      run.with_endpoint do
        assert_equal 401, run.deliver("bad-hmac", signature: "invalid", payload: "{")
        assert_equal 400, run.deliver("bad-json", payload: "{")
        assert_equal 400, run.deliver("json-comment", payload: '{"id":101}/*not JSON*/')
        assert_equal 400, run.deliver("duplicate-order-key", payload: '{"id":101,"id":102}')
        assert_equal 400, run.deliver("wrong-type", payload: "[]")
        assert_equal 400, run.deliver("no-order", payload: {})
        assert_equal 400, run.deliver("wrong-refund-order", topic: "refunds/create", payload: { order_id: "101" })
        assert_equal 400, run.deliver(nil)
        assert_equal 403, run.deliver("unknown-shop", shop: "other.myshopify.com")
        assert_equal 200, run.deliver("valid-raw-body", payload: " { \"id\":101 } \n")
      end
      assert_equal [[ALPHA, "valid-raw-body", ORDER, 0]], run.snapshot.fetch("inbox")
      assert_empty run.admin.requests
    end
  end

  def test_duplicate_reversed_deliveries_and_shop_currency_isolation
    ShopifyFixture.run do |run|
      run.admin.order([ShopifyScenarios.sale, ShopifyScenarios.refund,
                       ShopifyFixture.transaction("gid://shopify/OrderTransaction/203", "CAPTURE", "10.125", "USD"),
                       ShopifyFixture.transaction("gid://shopify/OrderTransaction/204", "REFUND", "0.005", "USD")])
      run.admin.order([ShopifyFixture.transaction(SALE, "SALE", "9.75")], shop: BETA)

      run.with_endpoint do
        assert_equal 200, run.deliver("same-id", topic: "refunds/create")
        assert_equal 200, run.deliver("same-id", topic: "refunds/create")
        assert_equal 200, run.deliver("order-after-refund")
        assert_equal 200, run.deliver("separate-refund-id", topic: "refunds/create")
        assert_equal 200, run.deliver("same-id", shop: BETA)
      end

      assert_empty run.admin.requests
      assert_equal 4, run.snapshot.fetch("inbox").length
      4.times { assert_equal({ "status" => "processed" }, run.worker) }
      assert_equal({ "status" => "idle" }, run.worker)
      expected = {
        "shop" => ALPHA,
        "totals" => ShopifyScenarios::AFTER.fetch("totals") +
          [{ "currency" => "USD", "collected" => "10.125", "refunded" => "0.005", "net" => "10.12" }]
      }
      assert_equal expected, run.summary
      assert_equal({ "shop" => BETA, "totals" => [
        { "currency" => "CAD", "collected" => "9.75", "refunded" => "0.00", "net" => "9.75" }
      ] }, run.summary(BETA))
      assert_equal 5, run.snapshot.fetch("transactions").length
    end
  end

  def test_pending_payment_can_become_successful_once
    ShopifyFixture.run do |run|
      pending = ShopifyFixture.transaction(REFUND, "REFUND", "25.00", "CAD", "PENDING")
      auth = ShopifyFixture.transaction("gid://shopify/OrderTransaction/203", "AUTHORIZATION", "100.00")
      failed = ShopifyFixture.transaction("gid://shopify/OrderTransaction/204", "REFUND", "90.00", "CAD", "FAILURE")
      run.admin.order([ShopifyScenarios.sale, pending, auth, failed])

      run.with_endpoint { assert_equal 200, run.deliver("pending-refund", topic: "refunds/create") }
      assert_equal({ "status" => "processed" }, run.worker)
      assert_equal ShopifyScenarios::BEFORE, run.summary
      assert_equal [SALE], run.snapshot.fetch("transactions").map { |row| row[1] }

      run.admin.order([ShopifyScenarios.sale, ShopifyScenarios.refund, auth, failed])
      run.with_endpoint { assert_equal 200, run.deliver("refund-complete") }
      assert_equal({ "status" => "processed" }, run.worker)
      assert_equal ShopifyScenarios::AFTER, run.summary
      assert_equal [SALE, REFUND], run.snapshot.fetch("transactions").map { |row| row[1] }
    end
  end

  def test_failed_and_incomplete_api_responses_leave_retryable_work_without_blocking_another_order
    ShopifyFixture.run do |run|
      run.admin.order([ShopifyScenarios.sale], count: 2)
      run.admin.order([], id: OTHER_ORDER)
      run.with_endpoint do
        assert_equal 200, run.deliver("incomplete-order")
        assert_equal 200, run.deliver("other-order", payload: { id: 102 })
      end
      assert_equal({ "status" => "retry" }, run.worker(success: false))
      assert_empty run.snapshot.fetch("transactions")
      assert_equal [[0, 1]], run.read("SELECT processed, attempts FROM inbox WHERE webhook_id = ?", ["incomplete-order"])
      assert_equal({ "status" => "processed" }, run.worker)
      assert_equal [0, 1], run.snapshot.fetch("inbox").map(&:last)

      [
        [503, { errors: [{ message: "synthetic API outage" }] }],
        [200, '{"data":{"order":{"id":"gid://shopify/Order/101","transactionsCount":{"count":0,"precision":"EXACT"},"transactions":[]}}}/*not JSON*/'],
        [200, { data: { order: { id: ORDER, transactions: [], transactionsCount: { count: 0, precision: "AT_LEAST" } } } }],
        [200, { data: { order: { id: ORDER, transactionsCount: { count: 1, precision: "EXACT" }, transactions: [{}] } } }]
      ].each_with_index do |(code, response), index|
        run.admin.arrange(ALPHA, "OrderPayments", ORDER, response, code: code)
        run.read("UPDATE inbox SET next_attempt_at = 0 WHERE webhook_id = ?", ["incomplete-order"])
        assert_equal({ "status" => "retry" }, run.worker(success: false), "API failure #{index}")
        assert_empty run.snapshot.fetch("transactions")
        assert_equal [[0, index + 2]], run.read("SELECT processed, attempts FROM inbox WHERE webhook_id = ?", ["incomplete-order"])
      end

      run.admin.order([ShopifyScenarios.sale])
      run.read("UPDATE inbox SET next_attempt_at = 0 WHERE webhook_id = ?", ["incomplete-order"])
      assert_equal({ "status" => "processed" }, run.worker)
      assert_equal ShopifyScenarios::BEFORE, run.summary
    end
  end

  def test_worker_rolls_back_ledger_when_processing_flag_write_fails
    ShopifyFixture.run do |run|
      run.admin.order([ShopifyScenarios.sale])
      run.with_endpoint { assert_equal 200, run.deliver("db-write-failure") }
      run.read(<<~SQL)
        CREATE TRIGGER fail_mark_processed BEFORE UPDATE OF processed ON inbox
        WHEN NEW.processed = 1
        BEGIN SELECT RAISE(ABORT, 'synthetic mark processed failure'); END;
      SQL
      assert_equal({ "status" => "retry" }, run.worker(success: false))
      assert_empty run.snapshot.fetch("transactions")
      assert_equal [0], run.snapshot.fetch("inbox").map(&:last)
      run.read("DROP TRIGGER fail_mark_processed")
      run.read("UPDATE inbox SET next_attempt_at = 0")
      assert_equal({ "status" => "processed" }, run.worker)
      assert_equal ShopifyScenarios::BEFORE, run.summary
    end
  end

  def test_webhook_write_lock_returns_retryable_error
    ShopifyFixture.run do |run|
      run.with_endpoint do
        assert_equal 200, run.deliver("seed")
        SQLite3::Database.new(run.database) do |connection|
          connection.execute("BEGIN IMMEDIATE")
          assert_equal 503, run.deliver("locked")
          connection.execute("ROLLBACK")
        end
        assert_equal ["seed"], run.snapshot.fetch("inbox").map { |row| row[1] }
        assert_equal 200, run.deliver("locked")
      end
      assert_equal %w[seed locked], run.snapshot.fetch("inbox").map { |row| row[1] }
    end
  end

  def test_missed_webhook
    evidence = ShopifyScenarios.missed_webhook
    assert_equal ShopifyScenarios::BEFORE, evidence.fetch("before")
    assert_equal ShopifyScenarios::AFTER, evidence.fetch("summary")
  end

  def test_reconciliation_retry
    evidence = ShopifyScenarios.reconciliation_retry
    assert_equal ShopifyScenarios::AFTER, evidence.fetch("summary")
    assert_equal [[ALPHA, evidence.fetch("before")]], evidence.fetch("after_failure").fetch("checkpoints")
  end

  def test_reconciliation_preserves_newer_checkpoint_written_during_fetch
    ShopifyFixture.run do |run|
      run.admin.page([])
      prior = run.reconcile.fetch("synced_through")
      newer = (Time.iso8601(prior) + 3600).iso8601
      page = { data: { orders: { nodes: [], pageInfo: { hasNextPage: false, endCursor: nil } } } }
      run.admin.arrange(ALPHA, "ReconcileOrders", nil, page) do |variables|
        # The worker has captured its upper bound and read the old checkpoint.
        # Use another SQLite connection to model a newer run finishing first.
        bound = variables.fetch("filter").split("updated_at:<='").last.delete_suffix("'")
        raise "test race did not advance the checkpoint" unless Time.iso8601(bound) < Time.iso8601(newer)

        run.read("UPDATE checkpoints SET synced_through = ? WHERE shop = ?", [newer, ALPHA])
      end
      assert_equal newer, run.reconcile.fetch("synced_through")
      assert_equal [[ALPHA, newer]], run.snapshot.fetch("checkpoints")
    end
  end
end
