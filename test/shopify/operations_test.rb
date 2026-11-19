require "minitest/autorun"
require_relative "../../lib/event_consumer/bundle"
require_relative "../support/shopify_scenarios"

class ShopifyOperationsTest < Minitest::Test
  include ShopifyFixture

  OUTAGE = { errors: [{ message: "synthetic API outage" }] }.freeze

  def make_due(run, webhook_id)
    run.read("UPDATE inbox SET next_attempt_at = 0 WHERE webhook_id = ?", [webhook_id])
  end

  def test_exhausted_delivery_is_parked_without_blocking_others_and_can_be_retried_once
    ShopifyFixture.run do |run|
      run.configure(max_attempts: 2)
      run.admin.order([], id: OTHER_ORDER)
      run.admin.arrange(ALPHA, "OrderPayments", ORDER, OUTAGE, code: 503)
      run.admin.arrange(ALPHA, "OrderPayments", ORDER, OUTAGE, code: 503)
      run.with_endpoint do
        assert_equal 200, run.deliver("poison")
        assert_equal 200, run.deliver("healthy", payload: { id: 102 })
      end

      assert_equal({ "status" => "retry" }, run.worker(success: false))
      make_due(run, "poison")
      _stdout, stderr, status = run.command("bin/shopify-worker", "--once")
      refute status.success?
      log = stderr.lines.map { |line| JSON.parse(line) }.find { |entry| entry["event"] == "delivery_parked" }
      assert_equal({ "shop" => ALPHA, "delivery" => "poison", "attempt" => 2 }, log.slice("shop", "delivery", "attempt"))
      refute_includes stderr, "fake-token"

      # A parked delivery is never selected again, even when its retry time has passed.
      make_due(run, "poison")
      assert_equal({ "status" => "processed" }, run.worker)
      assert_equal({ "status" => "idle" }, run.worker)

      parked = run.json("bin/shopify-deliveries", "list", ALPHA, "--state", "parked").fetch("deliveries")
      assert_equal [["poison", "parked", 2, 0]], parked.map { |d| d.values_at("webhook_id", "state", "attempts", "requeues") }
      assert_match(/HTTP 503/, parked.first.fetch("last_error"))
      refute_nil parked.first.fetch("parked_at")
      assert_empty run.json("bin/shopify-deliveries", "list", BETA, "--state", "all").fetch("deliveries")

      run.admin.order([ShopifyScenarios.sale])
      retried = run.json("bin/shopify-deliveries", "retry", ALPHA, "poison").fetch("delivery")
      assert_equal %w[pending 0 1], retried.values_at("state", "attempts", "requeues").map(&:to_s)
      assert_equal({ "status" => "processed" }, run.worker)
      assert_equal ShopifyScenarios::BEFORE, run.summary
      assert_equal [["delivery:poison"]], run.read("SELECT source FROM transactions")

      # Recovery of finished work is refused and changes nothing.
      refused = run.json("bin/shopify-deliveries", "retry", ALPHA, "poison", success: false)
      assert_equal "delivery already processed", refused.fetch("refused")
      assert_equal "delivery not found", run.json("bin/shopify-deliveries", "retry", BETA, "poison", success: false).fetch("refused")
      assert_equal [[1, 1, 0]], run.read("SELECT processed, requeues, attempts FROM inbox WHERE webhook_id = 'poison'")
    end
  end

  def test_deliveries_command_rejects_bad_usage_and_unconfigured_shops
    ShopifyFixture.run do |run|
      [[], %w[list], ["list", "unknown.myshopify.com"], ["list", ALPHA, "--state", "stuck"],
       ["retry", ALPHA], ["drop", ALPHA, "x"]].each do |arguments|
        stdout, stderr, status = run.command("bin/shopify-deliveries", *arguments)
        refute status.success?, arguments.inspect
        assert_empty stdout
        assert_match(/shopify ledger: ArgumentError/, stderr)
      end
    end
  end
end
