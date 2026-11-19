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

  def test_worker_rejects_bad_drain_arguments
    ShopifyFixture.run do |run|
      [%w[--drain --limit 0], %w[--drain --limit x], %w[--drain --limit], %w[--drain --once], []].each do |args|
        stdout, stderr, process = run.command("bin/shopify-worker", *args)
        assert_equal 1, process.exitstatus, args.inspect
        assert_empty stdout
        assert_includes stderr, "usage: bin/shopify-worker --once | --drain [--limit N]"
      end
    end
  end
end
