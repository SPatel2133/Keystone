require "minitest/autorun"
require_relative "../../lib/event_consumer/bundle"
require_relative "../support/shopify_scenarios"

class ShopifyDrainTest < Minitest::Test
  include ShopifyFixture

  ORDERS = 40
  WORKERS = 4

  def order(number) = "gid://shopify/Order/#{number}"

  def arrange_orders(run, count)
    run.with_endpoint do
      count.times do |index|
        number = 1000 + index
        run.admin.order([ShopifyFixture.transaction("gid://shopify/OrderTransaction/#{number}", "SALE", "#{number}.01")],
                        id: order(number))
        assert_equal 200, run.deliver("drain-#{number}", payload: { id: number, admin_graphql_api_id: order(number) })
      end
    end
  end

  def test_concurrent_drains_apply_every_delivery_exactly_once
    ShopifyFixture.run do |run|
      arrange_orders(run, ORDERS)
      workers = Array.new(WORKERS) { run.spawn("bin/shopify-worker", "--drain") }
      results = workers.map do |stdin, stdout, stderr, waiter|
        stdin.close
        output = stdout.read
        stderr.read
        assert waiter.value.success?, output
        JSON.parse(output)
      end

      assert_equal ORDERS, results.sum { |result| result.fetch("processed") }
      assert results.all? { |result| result.values_at("status", "retry", "parked") == ["idle", 0, 0] }, results.inspect
      # Sum of 1000.01 through 1039.01.
      assert_equal [{ "currency" => "CAD", "collected" => "40780.40", "refunded" => "0.00", "net" => "40780.40" }],
                   run.summary.fetch("totals")
      assert_equal [[ORDERS, ORDERS]], run.read("SELECT COUNT(*), COUNT(DISTINCT transaction_id) FROM transactions")
      assert_equal [[0]], run.read("SELECT COUNT(*) FROM inbox WHERE processed = 0")
      # Each transaction names the delivery that recorded it.
      assert_equal [[ORDERS]], run.read("SELECT COUNT(*) FROM transactions t JOIN inbox i " \
                                        "ON t.source = 'delivery:' || i.webhook_id AND t.order_id = i.order_id")
      # Claims keep live workers off each other's orders: one Admin fetch per delivery.
      assert_equal ORDERS, run.admin.requests.count { |request| request.fetch("operation") == "OrderPayments" }
      assert_equal [[0]], run.read("SELECT COUNT(*) FROM inbox WHERE claimed_by IS NOT NULL")
    end
  end

  def test_drain_honours_limit_and_reports_deferred_and_parked_work
    ShopifyFixture.run do |run|
      run.configure(max_attempts: 1)
      arrange_orders(run, 3)
      run.admin.arrange(ALPHA, "OrderPayments", order(1001), { errors: [{ message: "gone" }] }, code: 404)

      assert_equal({ "processed" => 1, "retry" => 0, "parked" => 0, "status" => "limit" },
                   run.json("bin/shopify-worker", "--drain", "--limit", "1"))
      assert_equal({ "processed" => 1, "retry" => 0, "parked" => 1, "status" => "idle" },
                   run.json("bin/shopify-worker", "--drain", success: false))
      assert_equal({ "processed" => 0, "retry" => 0, "parked" => 0, "status" => "idle" },
                   run.json("bin/shopify-worker", "--drain"))
    end
  end

  def test_a_live_claim_keeps_other_workers_off_the_order_until_it_finishes
    ShopifyFixture.run do |run|
      arrange_orders(run, 1)
      body = { data: { order: { id: order(1000), transactions: [ShopifyFixture.transaction("gid://shopify/OrderTransaction/1000", "SALE", "1000.01")],
                                transactionsCount: { count: 1, precision: "EXACT" } } } }
      competing = nil
      run.admin.arrange(ALPHA, "OrderPayments", order(1000), body) do
        competing ||= run.json("bin/shopify-worker", "--once")
      end
      assert_equal({ "status" => "processed" }, run.worker)
      # The competing worker ran while the first was mid-fetch and found nothing to claim.
      assert_equal({ "status" => "idle" }, competing)
      assert_equal 1, run.admin.requests.size
    end
  end

  def test_one_fetch_completes_earlier_deliveries_for_the_order_but_not_later_ones
    ShopifyFixture.run do |run|
      run.admin.order([ShopifyScenarios.sale])
      run.with_endpoint do
        assert_equal 200, run.deliver("update-1")
        assert_equal 200, run.deliver("update-2")
        assert_equal 200, run.deliver("refund-1", topic: "refunds/create")
        sent = false
        run.admin.arrange(ALPHA, "OrderPayments", ORDER, { data: { order: {
          id: ORDER, transactions: [ShopifyScenarios.sale], transactionsCount: { count: 1, precision: "EXACT" }
        } } }) do
          next if sent

          sent = true
          # Arrives while the first fetch is in flight, so that fetch may predate it.
          assert_equal 200, run.deliver("update-during-fetch")
          run.admin.order([ShopifyScenarios.sale, ShopifyScenarios.refund])
        end
        counts = run.json("bin/shopify-worker", "--drain")
        assert_equal 2, counts.fetch("processed")
      end
      assert_equal 2, run.admin.requests.count { |request| request["operation"] == "OrderPayments" }
      assert_equal [[4]], run.read("SELECT SUM(processed) FROM inbox")
      assert_equal ShopifyScenarios::AFTER, run.summary
    end
  end

  def test_claim_of_a_dead_process_is_taken_over_but_a_live_claim_is_respected
    ShopifyFixture.run do |run|
      run.admin.order([ShopifyScenarios.sale])
      run.with_endpoint { assert_equal 200, run.deliver("claimed") }
      far = Time.now.to_i + 3600
      run.read("UPDATE inbox SET claimed_by = ?, claimed_until = ?", [Process.pid, far])
      assert_equal({ "processed" => 0, "retry" => 0, "parked" => 0, "status" => "idle" }, run.json("bin/shopify-worker", "--drain"))
      assert_equal 0, run.admin.requests.size

      dead = Process.spawn("true")
      Process.wait(dead)
      run.read("UPDATE inbox SET claimed_by = ?, claimed_until = ?", [dead, far])
      assert_equal 1, run.json("bin/shopify-worker", "--drain").fetch("processed")
      assert_equal [[1, nil, nil]], run.read("SELECT processed, claimed_by, claimed_until FROM inbox")
    end
  end

  def test_watch_processes_new_deliveries_and_stops_cleanly_on_sigterm
    ShopifyFixture.run do |run|
      run.admin.order([ShopifyScenarios.sale])
      stdin, stdout, stderr, waiter = run.spawn("bin/shopify-worker", "--watch")
      stdin.close
      run.with_endpoint { assert_equal 200, run.deliver("late") }
      deadline = Time.now + 10
      sleep 0.1 until run.read("SELECT processed FROM inbox") == [[1]] || Time.now > deadline
      Process.kill("TERM", waiter.pid)
      assert waiter.value.success?
      stderr.read
      assert_equal({ "processed" => 1, "retry" => 0, "parked" => 0, "status" => "stopped" }, JSON.parse(stdout.read))
    end
  end

  def test_worker_rejects_bad_drain_arguments
    ShopifyFixture.run do |run|
      [%w[--drain --limit 0], %w[--drain --limit x], %w[--drain --limit], %w[--drain --once], []].each do |args|
        stdout, stderr, process = run.command("bin/shopify-worker", *args)
        assert_equal 1, process.exitstatus, args.inspect
        assert_empty stdout
        assert_includes stderr, "usage: bin/shopify-worker --once | --drain [--limit N] | --watch"
      end
    end
  end
end
