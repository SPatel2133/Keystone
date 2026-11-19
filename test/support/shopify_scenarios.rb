require_relative "shopify_fixture"
require "time"

module ShopifyScenarios
  include ShopifyFixture
  extend self

  BEFORE = { "shop" => ALPHA, "totals" => [
    { "currency" => "CAD", "collected" => "100.00", "refunded" => "0.00", "net" => "100.00" }
  ] }.freeze
  AFTER = { "shop" => ALPHA, "totals" => [
    { "currency" => "CAD", "collected" => "100.00", "refunded" => "25.00", "net" => "75.00" }
  ] }.freeze

  def equal(expected, actual, context)
    return actual if expected.eql?(actual)

    raise "#{context}: expected #{expected.inspect}, observed #{actual.inspect}"
  end

  def sale
    ShopifyFixture.transaction(SALE, "SALE", "100.00")
  end

  def refund
    ShopifyFixture.transaction(REFUND, "REFUND", "25.00")
  end

  def seed_payment(run)
    run.admin.order([sale])
    run.with_endpoint { equal(200, run.deliver("sale-notice"), "sale webhook") }
    equal({ "status" => "processed" }, run.worker, "sale worker")
    equal(BEFORE, run.summary, "initial payment summary")
  end

  def worker_crash(seam)
    raise "unknown worker seam #{seam.inspect}" unless %w[before_commit after_commit].include?(seam)

    ShopifyFixture.run do |run|
      seed_payment(run)
      run.admin.order([sale, refund])
      run.with_endpoint do
        equal(200, run.deliver("refund-notice", topic: "refunds/create"), "refund webhook")
      end
      stdout, stderr, status = run.command("test/support/shopify-worker-with-hooks", "--once", seam: seam)
      child = CrashHarness.observation(stdout, stderr, status)
      equal(CrashHarness.killed, child, "worker #{seam} process outcome")
      durable = run.snapshot
      processed = seam == "after_commit" ? 1 : 0
      sale_row = [ALPHA, SALE, "CAD", "SALE", "100.00"]
      refund_row = [ALPHA, REFUND, "CAD", "REFUND", "25.00"]
      expected_transactions = processed == 1 ? [sale_row, refund_row] : [sale_row]
      equal([[ALPHA, "sale-notice", ORDER, 1], [ALPHA, "refund-notice", ORDER, processed]],
            durable.fetch("inbox"), "worker #{seam} durable inbox")
      equal(expected_transactions, durable.fetch("transactions"), "worker #{seam} durable transactions")
      equal(processed == 1 ? AFTER : BEFORE, run.summary, "summary before restart")

      restart = run.worker
      equal({ "status" => processed == 1 ? "idle" : "processed" }, restart, "worker restart")
      summary = equal(AFTER, run.summary, "summary after restart")
      final = run.snapshot
      equal([1, 1], final.fetch("inbox").map(&:last), "final processed flags")
      equal([sale_row, refund_row], final.fetch("transactions"), "final transactions")
      { "type" => "worker_crash", "seam" => seam, "child" => child, "before_restart" => durable,
        "restart" => restart, "summary" => summary, "after_restart" => final }
    end
  end

  def lost_webhook_ack
    ShopifyFixture.run do |run|
      request = lambda { run.deliver("lost-ack", topic: "refunds/create") }
      status = nil
      lost = run.with_endpoint(seam: "after_commit_before_ack") do |waiter|
        begin
          response = request.call
          raise "Expected an interrupted request, got HTTP #{response}"
        rescue EOFError, Errno::ECONNRESET, Errno::EPIPE => error
          waiter.join(5) or raise "Webhook endpoint did not exit after lost acknowledgment"
          status = waiter.value
          error.class.name
        end
      end
      equal(Signal.list.fetch("KILL"), status.termsig, "webhook SIGKILL")
      expected = [[ALPHA, "lost-ack", ORDER, 0]]
      equal(expected, run.snapshot.fetch("inbox"), "durable inbox before resend")
      retry_code = run.with_endpoint { equal(200, request.call, "webhook retry") }
      equal(expected, run.snapshot.fetch("inbox"), "one durable delivery after resend")
      equal([], run.admin.requests, "API calls in webhook handler")
      { "type" => "lost_webhook_ack", "signal" => status.termsig, "client_error" => lost,
        "before_retry" => expected, "retry_http_status" => retry_code }
    end
  end

  def missed_webhook
    ShopifyFixture.run do |run|
      seed_payment(run)
      before = run.summary
      run.admin.order([sale, refund])
      run.admin.page([ORDER])
      reconciliation = run.reconcile
      summary = equal(AFTER, run.summary, "missed webhook repair")
      durable = run.snapshot
      equal([[ALPHA, "sale-notice", ORDER, 1]], durable.fetch("inbox"), "no refund webhook delivered")
      equal([[ALPHA, reconciliation.fetch("synced_through")]], durable.fetch("checkpoints"), "repair checkpoint")
      { "type" => "missed_webhook", "before" => before, "reconciliation" => reconciliation,
        "summary" => summary, "durable" => durable }
    end
  end

  def reconciliation_retry
    ShopifyFixture.run do |run|
      run.admin.page([])
      initial = Time.iso8601(run.reconcile.fetch("synced_through"))
      # Model a previous successful run. Even on a fast machine, updating the
      # checkpoint before page two completes must be observable.
      start = (initial - 3600).iso8601
      run.read("UPDATE checkpoints SET synced_through = ? WHERE shop = ?", [start, ALPHA])
      run.admin.page([ORDER], next_cursor: "page-2")
      run.admin.arrange(ALPHA, "ReconcileOrders", "page-2", { errors: [{ message: "test outage" }] }, code: 503)
      run.admin.order([sale])
      failure = run.reconcile(success: false)
      durable = run.snapshot
      equal([[ALPHA, start]], durable.fetch("checkpoints"), "checkpoint after page-two failure")
      equal(BEFORE, run.summary, "page-one ledger changes remain usable")
      equal([SALE], durable.fetch("transactions").map { |row| row[1] }, "page-one durable rows")
      equal([], durable.fetch("inbox"), "reconciliation does not enqueue webhook deliveries")

      run.admin.page([OTHER_ORDER], after: "page-2")
      run.admin.order([refund], id: OTHER_ORDER)
      retry_result = run.reconcile
      equal(AFTER, run.summary, "retried reconciliation")
      retried = run.snapshot
      equal([[ALPHA, retry_result.fetch("synced_through")]], retried.fetch("checkpoints"), "retry checkpoint")
      raise "Successful retry failed to advance checkpoint" unless Time.iso8601(retry_result.fetch("synced_through")) > Time.iso8601(start)

      rerun = run.reconcile
      equal(AFTER, run.summary, "overlapping reconciliation")
      equal(retried.fetch("transactions"), run.snapshot.fetch("transactions"), "overlap leaves durable transactions unchanged")

      pages = run.admin.requests.select { |request| request["operation"] == "ReconcileOrders" }.map { |request| request.fetch("variables") }
      # The retry resumes the failed window at its saved cursor, then scans a fresh window to now.
      equal([nil, nil, "page-2", "page-2", nil, "page-2", nil, "page-2"], pages.map { |variables| variables["after"] }, "retry resumes at saved cursor")
      [[1, 2], [2, 3], [4, 5], [6, 7]].each do |first, second|
        equal(pages[first].fetch("filter"), pages[second].fetch("filter"), "fixed time bound within each run")
      end
      bounds = pages.map do |page|
        window = page.fetch("filter").match(/\Aupdated_at:>='([^']+)' updated_at:<='([^']+)'\z/)
        raise "unexpected reconciliation filter #{page.inspect}" unless window

        window.captures.map { |iso| Time.iso8601(iso) }
      end
      equal(7 * 86_400, (bounds[0][1] - bounds[0][0]).to_i, "initial seven-day lookback")
      equal(Time.iso8601(start) - 300, bounds[1][0], "five-minute overlap after first checkpoint")
      equal(bounds[1][0], bounds[3][0], "failed run did not advance retry's lower bound")
      equal(bounds[1][1] - 300, bounds[4][0], "fresh window overlaps the resumed window")
      equal(Time.iso8601(retry_result.fetch("synced_through")) - 300, bounds[6][0], "overlap after retry checkpoint")
      {
        "type" => "reconciliation_retry", "before" => start, "failure" => failure,
        "after_failure" => durable, "retry" => retry_result, "overlap" => rerun,
        "summary" => run.summary, "page_requests" => pages
      }
    end
  end
end
