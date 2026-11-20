require "time"
require_relative "payments"
require_relative "storage"

module ShopifyLedger
  # Operational snapshot for one or more shops. Each shop is read in one read
  # transaction so counts, checkpoints and totals are mutually consistent. The
  # SQL is valid in SQLite and PostgreSQL (pass store: Postgres::Store).
  class Status
    PENDING_AGE_LIMIT = 15 * 60
    CHECKPOINT_AGE_LIMIT = 2 * 60 * 60

    def initialize(config, clock: -> { Time.now }, store: nil)
      @config = config
      @store = store
      @clock = clock
    end

    def report(shops)
      now = @clock.call.to_i
      shops.map do |shop|
        store = @store || Storage::Store.new(@config.database_for(shop))
        store.connect { |db| store.read(db) { shop_status(db, shop, now) } }
      end
    end

    # Prometheus text exposition of the counts and ages in a report. Money is
    # left out on purpose: metric samples are floats, and totals must stay exact.
    def self.prometheus(report)
      metrics = {
        "shopify_ledger_healthy" => ["gauge", "1 when the shop needs no attention", []],
        "shopify_ledger_deliveries" => ["gauge", "Webhook deliveries by state", []],
        "shopify_ledger_oldest_pending_delivery_age_seconds" => ["gauge", "Age of the oldest pending delivery", []],
        "shopify_ledger_reconciliation_checkpoint_age_seconds" => ["gauge", "Age of the reconciliation checkpoint", []],
        "shopify_ledger_reconciliation_open_run" => ["gauge", "1 when a reconciliation run is unfinished", []],
        "shopify_ledger_transactions" => ["gauge", "Stored payment transactions by recording source", []],
        "shopify_ledger_payment_review" => ["gauge", "Payments an operator should look at, by reason", []]
      }
      report.each do |shop|
        label = %(shop="#{shop[:shop]}")
        deliveries = shop[:deliveries]
        reconciliation = shop[:reconciliation]
        transactions = shop[:transactions]
        metrics["shopify_ledger_healthy"][2] << ["{#{label}}", shop[:health] == "ok" ? 1 : 0]
        %i[pending failing parked processed].each do |state|
          metrics["shopify_ledger_deliveries"][2] << [%({#{label},state="#{state}"}), deliveries[state]]
        end
        metrics["shopify_ledger_oldest_pending_delivery_age_seconds"][2] << ["{#{label}}", deliveries[:oldest_pending_age_seconds] || 0]
        age = reconciliation[:checkpoint_age_seconds]
        metrics["shopify_ledger_reconciliation_checkpoint_age_seconds"][2] << ["{#{label}}", age] if age
        metrics["shopify_ledger_reconciliation_open_run"][2] << ["{#{label}}", reconciliation[:open_run] ? 1 : 0]
        { "delivery" => :from_webhooks, "reconciliation" => :repaired_by_reconciliation, "unknown" => :unknown_source }.each do |source, key|
          metrics["shopify_ledger_transactions"][2] << [%({#{label},source="#{source}"}), transactions[key]]
        end
        { open_transactions: "open_transaction", orders_refunded_beyond_collected: "refund_exceeds_payments",
          authorizations_captured_beyond_amount: "capture_exceeds_authorization" }.each do |key, reason|
          metrics["shopify_ledger_payment_review"][2] << [%({#{label},reason="#{reason}"}), shop[:payments][key]]
        end
      end
      metrics.flat_map do |name, (type, help, samples)|
        ["# HELP #{name} #{help}", "# TYPE #{name} #{type}"] + samples.map { |labels, value| "#{name}#{labels} #{value}" }
      end.join("\n")
    end

    private

    def shop_status(db, shop, now)
      deliveries = deliveries(db, shop, now)
      reconciliation = reconciliation(db, shop, now)
      transactions = transactions(db, shop)
      totals, totals_error = begin
        [Payments.summary(db, shop), nil]
      rescue Payments::Error => error
        [nil, error.message]
      end
      reasons = attention(deliveries, reconciliation, totals_error)
      {
        shop: shop, health: reasons.empty? ? "ok" : "attention", reasons: reasons,
        deliveries: deliveries, reconciliation: reconciliation, transactions: transactions,
        payments: payments(db, shop), totals: totals, totals_error: totals_error
      }.compact
    end

    def deliveries(db, shop, now)
      pending, failing, parked, processed, oldest, undated, next_retry, max_attempts = db.get_first_row(<<~SQL, [shop])
        SELECT
          COALESCE(SUM(CASE WHEN processed = 0 AND parked_at IS NULL THEN 1 ELSE 0 END), 0),
          COALESCE(SUM(CASE WHEN processed = 0 AND parked_at IS NULL AND attempts > 0 THEN 1 ELSE 0 END), 0),
          COALESCE(SUM(CASE WHEN processed = 0 AND parked_at IS NOT NULL THEN 1 ELSE 0 END), 0),
          COALESCE(SUM(CASE WHEN processed = 1 THEN 1 ELSE 0 END), 0),
          MIN(CASE WHEN processed = 0 AND parked_at IS NULL THEN received_at END),
          COALESCE(SUM(CASE WHEN processed = 0 AND parked_at IS NULL AND received_at IS NULL THEN 1 ELSE 0 END), 0),
          MIN(CASE WHEN processed = 0 AND parked_at IS NULL AND attempts > 0 THEN next_attempt_at END),
          COALESCE(MAX(CASE WHEN processed = 0 THEN attempts END), 0)
        FROM inbox WHERE shop = ?
      SQL
      {
        pending: pending, failing: failing, parked: parked, processed: processed,
        oldest_pending_age_seconds: oldest && [now - oldest, 0].max,
        pending_without_receipt_time: undated,
        next_retry_at: next_retry && Time.at(next_retry).utc.iso8601,
        max_attempts_seen: max_attempts, max_attempts_allowed: @config.max_attempts
      }
    end

    def reconciliation(db, shop, now)
      checkpoint = db.get_first_value("SELECT synced_through FROM checkpoints WHERE shop = ?", [shop])
      open = db.get_first_row(<<~SQL, [shop])
        SELECT id, status, window_start, window_end, pages, orders, attempts, last_error, updated_at
        FROM reconciliation_runs WHERE shop = ? AND status <> 'completed'
      SQL
      last = db.get_first_row(<<~SQL, [shop])
        SELECT id, window_start, window_end, pages, orders, attempts, finished_at
        FROM reconciliation_runs WHERE shop = ? AND status = 'completed' ORDER BY id DESC LIMIT 1
      SQL
      {
        synced_through: checkpoint,
        checkpoint_age_seconds: checkpoint && [now - Time.iso8601(checkpoint).to_i, 0].max,
        open_run: open && %i[id status window_start window_end pages orders attempts last_error].zip(open).to_h
                             .merge(updated_at: Time.at(open[8]).utc.iso8601),
        last_completed_run: last && %i[id window_start window_end pages orders attempts].zip(last).to_h
                                       .merge(finished_at: Time.at(last[6]).utc.iso8601)
      }
    end

    def transactions(db, shop)
      total, delivery, reconciliation = db.get_first_row(<<~SQL, [shop])
        SELECT COUNT(*), COALESCE(SUM(CASE WHEN source LIKE 'delivery:%' THEN 1 ELSE 0 END), 0),
               COALESCE(SUM(CASE WHEN source LIKE 'reconciliation:%' THEN 1 ELSE 0 END), 0)
        FROM transactions WHERE shop = ?
      SQL
      { total: total, from_webhooks: delivery, repaired_by_reconciliation: reconciliation,
        unknown_source: total - delivery - reconciliation }
    end

    def payments(db, shop)
      review = Payments.review(db, shop)
      { open_transactions: review[:open_transactions],
        orders_refunded_beyond_collected: review[:refunds_exceeding_collected].map { |row| row[:order_id] }.uniq.size,
        authorizations_captured_beyond_amount: review[:captures_exceeding_authorization].size }
    end

    def attention(deliveries, reconciliation, totals_error)
      reasons = []
      parked = deliveries[:parked]
      reasons << "#{parked} parked #{parked == 1 ? 'delivery needs' : 'deliveries need'} operator review" if parked.positive?
      age = deliveries[:oldest_pending_age_seconds]
      reasons << "oldest pending delivery has waited #{age}s" if age && age > PENDING_AGE_LIMIT
      run = reconciliation[:open_run]
      reasons << "reconciliation run #{run[:id]} failed: #{run[:last_error]}" if run && run[:status] == "failed"
      checkpoint_age = reconciliation[:checkpoint_age_seconds]
      if checkpoint_age.nil?
        reasons << "reconciliation has never completed"
      elsif checkpoint_age > CHECKPOINT_AGE_LIMIT
        reasons << "reconciliation checkpoint is #{checkpoint_age}s old"
      end
      reasons << "totals unavailable: #{totals_error}" if totals_error
      reasons
    end
  end
end
