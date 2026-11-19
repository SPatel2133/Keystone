require "minitest/autorun"
require_relative "../../lib/event_consumer/bundle"
require_relative "../support/shopify_fixture"

class ShopifyPaymentDomainTest < Minitest::Test
  include ShopifyFixture

  AUTH = "gid://shopify/OrderTransaction/301".freeze

  def tx(number, kind, amount, currency = "CAD", status = "SUCCESS", **options)
    ShopifyFixture.transaction("gid://shopify/OrderTransaction/#{number}", kind, amount, currency, status, **options)
  end

  def process(run, *transactions, webhook:, success: true)
    run.admin.order(transactions)
    run.with_endpoint { assert_equal 200, run.deliver(webhook) }
    run.worker(success: success)
  end

  def net(run, currency = "CAD")
    run.summary.fetch("totals").find { |row| row["currency"] == currency }&.fetch("net")
  end

  def test_partial_captures_void_and_only_successful_payments_move_money
    ShopifyFixture.run do |run|
      ledger = [tx(301, "AUTHORIZATION", "100.00"),
                tx(302, "CAPTURE", "30.00", parent: AUTH),
                tx(303, "CAPTURE", "50.00", parent: AUTH),
                tx(304, "CAPTURE", "10.00", "CAD", "FAILURE", parent: AUTH),
                tx(305, "CAPTURE", "5.00", "CAD", "PENDING", parent: AUTH),
                tx(306, "VOID", "15.00", parent: AUTH),
                tx(307, "SALE", "7.00", "CAD", "ERROR")]
      assert_equal({ "status" => "processed" }, process(run, *ledger, webhook: "first"))
      assert_equal "80.00", net(run)
      audit = run.json("bin/shopify-audit", ALPHA, "--order", ORDER)
      assert_equal %w[AUTHORIZATION CAPTURE CAPTURE CAPTURE CAPTURE VOID SALE].sort,
                   audit.fetch("shopify_transactions").map { |row| row["kind"] }.sort
      assert_equal 1, audit.fetch("review").fetch("open_transactions")
      assert_equal [AUTH] * 5, audit.fetch("shopify_transactions").filter_map { |row| row["parent_transaction_id"] }

      # The pending capture succeeds later; then a stale fetch reports it pending again.
      ledger[4] = tx(305, "CAPTURE", "5.00", parent: AUTH)
      assert_equal({ "status" => "processed" }, process(run, *ledger, webhook: "captured"))
      assert_equal "85.00", net(run)
      ledger[4] = tx(305, "CAPTURE", "5.00", "CAD", "PENDING", parent: AUTH)
      assert_equal({ "status" => "processed" }, process(run, *ledger, webhook: "stale"))
      assert_equal "85.00", net(run)
      assert_equal [["SUCCESS"]], run.read("SELECT status FROM payment_events WHERE transaction_id LIKE '%/305'")
      assert_equal 0, run.json("bin/shopify-status", ALPHA, success: false).fetch("shops").first.fetch("payments").fetch("open_transactions")
    end
  end

  def test_over_capture_and_refund_beyond_collected_are_reported_not_rejected
    ShopifyFixture.run do |run|
      ledger = [tx(301, "AUTHORIZATION", "50.00"), tx(302, "CAPTURE", "40.00", parent: AUTH),
                tx(303, "CAPTURE", "20.00", parent: AUTH), tx(304, "REFUND", "100.00")]
      assert_equal({ "status" => "processed" }, process(run, *ledger, webhook: "first"))
      assert_equal "-40.00", net(run)
      review = run.json("bin/shopify-audit", ALPHA).fetch("review")
      assert_equal [{ "order_id" => ORDER, "currency" => "CAD", "collected" => "60.00", "refunded" => "100.00" }],
                   review.fetch("refunds_exceeding_collected")
      assert_equal [{ "authorization_id" => AUTH, "order_id" => ORDER, "currency" => "CAD", "authorized" => "50.00",
                      "captured" => "60.00" }], review.fetch("captures_exceeding_authorization")
      # Status exits 2 because reconciliation never ran here; the payments block is still reported.
      payments = run.json("bin/shopify-status", ALPHA, success: false).fetch("shops").first.fetch("payments")
      assert_equal({ "open_transactions" => 0, "orders_refunded_beyond_collected" => 1,
                     "authorizations_captured_beyond_amount" => 1 }, payments)
    end
  end

  def test_refund_seen_before_its_sale_and_duplicated_refund_webhooks_count_once
    ShopifyFixture.run do |run|
      refund = tx(202, "REFUND", "25.00")
      run.admin.order([refund])
      run.with_endpoint do
        assert_equal 200, run.deliver("refund-a", topic: "refunds/create")
        assert_equal 200, run.deliver("refund-a", topic: "refunds/create")
        assert_equal 200, run.deliver("refund-b", topic: "refunds/create")
      end
      assert_equal({ "status" => "processed" }, run.worker)
      assert_equal "-25.00", net(run)
      assert_equal({ "status" => "processed" }, process(run, tx(201, "SALE", "100.00"), refund, webhook: "sale"))
      assert_equal "75.00", net(run)
      assert_equal [[2]], run.read("SELECT COUNT(*) FROM transactions")
      assert_equal [[3]], run.read("SELECT COUNT(*) FROM inbox")
    end
  end

  def test_presentment_money_is_stored_but_never_converted_or_coerced
    ShopifyFixture.run do |run|
      sale = tx(201, "SALE", "100.00", presentment: ["68.37", "EUR"])
      assert_equal({ "status" => "processed" }, process(run, sale, webhook: "sale"))
      assert_equal [["CAD", "100.00", "EUR", "68.37"]],
                   run.read("SELECT currency, amount, presentment_currency, presentment_amount FROM transactions")
      assert_equal [["CAD"]], run.read("SELECT DISTINCT currency FROM transactions")

      mismatch = tx(203, "SALE", "10.00", presentment: ["9.99", "CAD"])
      assert_equal({ "status" => "retry" }, process(run, sale, mismatch, webhook: "mismatch", success: false))
      cross = tx(204, "REFUND", "5.00", "USD", parent: "gid://shopify/OrderTransaction/201")
      run.admin.order([sale, cross])
      run.command("bin/shopify-deliveries", "retry", ALPHA, "mismatch")
      run.read("UPDATE inbox SET next_attempt_at = 0")
      assert_equal({ "status" => "retry" }, run.worker(success: false))
      errors = run.read("SELECT last_error FROM inbox WHERE webhook_id = 'mismatch'").flatten.join
      assert_match(/REFUND .*204 is in USD but its parent is in CAD/, errors)
      assert_equal "100.00", net(run)
      assert_equal [[1]], run.read("SELECT COUNT(*) FROM transactions")
    end
  end

  def test_final_status_cannot_change_to_another_final_status
    ShopifyFixture.run do |run|
      assert_equal({ "status" => "processed" }, process(run, tx(201, "SALE", "100.00"), webhook: "sale"))
      assert_equal({ "status" => "retry" },
                   process(run, tx(201, "SALE", "100.00", "CAD", "FAILURE"), webhook: "flip", success: false))
      assert_match(/changed from SUCCESS to FAILURE/, run.read("SELECT last_error FROM inbox WHERE webhook_id = 'flip'").flatten.first)
      assert_equal "100.00", net(run)
    end
  end

  def test_three_decimal_and_zero_decimal_currencies_stay_exact
    ShopifyFixture.run do |run|
      ledger = [tx(201, "SALE", "1.234", "BHD"), tx(202, "CAPTURE", "2.001", "BHD"), tx(203, "REFUND", "0.235", "BHD")]
      assert_equal({ "status" => "processed" }, process(run, *ledger, webhook: "bhd"))
      run.admin.order([tx(211, "SALE", "1500", "JPY"), tx(212, "SALE", "2500", "JPY", presentment: ["16.85", "USD"])],
                      id: OTHER_ORDER)
      run.with_endpoint { assert_equal 200, run.deliver("jpy", payload: { id: 102, admin_graphql_api_id: OTHER_ORDER }) }
      assert_equal({ "status" => "processed" }, run.worker)
      bhd = run.summary.fetch("totals").find { |row| row["currency"] == "BHD" }
      assert_equal({ "currency" => "BHD", "collected" => "3.235", "refunded" => "0.235", "net" => "3.00" }, bhd)
      assert_equal "4000.00", net(run, "JPY")
    end
  end

  def test_rows_from_the_previous_schema_gain_presentment_money_without_changing_amounts
    ShopifyFixture.run do |run|
      SQLite3::Database.new(run.database) do |db|
        ShopifyLedger::Storage::MIGRATIONS.first(3).flatten.each { |statement| db.execute(statement) }
        db.execute("INSERT INTO transactions (shop, transaction_id, order_id, currency, kind, amount) VALUES (?, ?, ?, ?, ?, ?)",
                   [ALPHA, SALE, ORDER, "CAD", "SALE", "100.00"])
      end
      assert_equal "100.00", net(run)
      assert_equal [[nil, nil]], run.read("SELECT presentment_currency, presentment_amount FROM transactions")
      assert_equal({ "status" => "processed" },
                   process(run, tx(201, "SALE", "100.00", presentment: ["68.37", "EUR"]), webhook: "sale"))
      assert_equal [["100.00", "EUR", "68.37"]], run.read("SELECT amount, presentment_currency, presentment_amount FROM transactions")
      assert_equal "100.00", net(run)
    end
  end
end
