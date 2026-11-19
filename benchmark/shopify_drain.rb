#!/usr/bin/env ruby
# Drains DELIVERIES webhooks with 1, 2, 4 and 8 concurrent `bin/shopify-worker
# --drain` processes against the local fake Admin API, which delays each order
# fetch by LATENCY_MS. UPDATES webhooks are sent per order, interleaved, as
# Shopify does when an order changes several times; deliveries = ORDERS * UPDATES.
# With BACKEND=postgres, webhooks go to SHOPIFY_LEDGER_POSTGRES_URL and the
# workers are `bin/shopify-pg-worker --drain`, each with its own machine ID.
# Usage: ruby benchmark/shopify_drain.rb [ORDERS] [LATENCY_MS] [UPDATES] [sqlite|postgres]
require_relative "../lib/event_consumer/bundle"
require_relative "../test/support/shopify_scenarios"

orders = Integer(ARGV.fetch(0, "200"))
latency = Integer(ARGV.fetch(1, "50")) / 1000.0
updates = Integer(ARGV.fetch(2, "1"))
backend = ARGV.fetch(3, "sqlite")
abort "backend must be sqlite or postgres" unless %w[sqlite postgres].include?(backend)
pg = nil
if backend == "postgres"
  require_relative "../lib/shopify_ledger/postgres"
  ENV["SHOPIFY_LEDGER_INBOX"] = "postgres"
  base_url = ENV.fetch("SHOPIFY_LEDGER_POSTGRES_URL")
  schema = "shopify_ledger_scratch_#{Process.pid}"
  plain = ShopifyLedger::Postgres::Database.new(base_url)
  begin
    plain.execute("CREATE SCHEMA IF NOT EXISTS #{schema}")
  ensure
    plain.close
  end
  ENV["SHOPIFY_LEDGER_POSTGRES_URL"] = ShopifyLedger::Postgres.scratch_url(base_url, schema)
  at_exit do
    pg&.close
    cleanup = ShopifyLedger::Postgres::Database.new(base_url)
    begin
      cleanup.execute("DROP SCHEMA IF EXISTS #{schema} CASCADE")
    ensure
      cleanup.close
    end
  end
  pg = ShopifyLedger::Postgres::Database.new(ENV.fetch("SHOPIFY_LEDGER_POSTGRES_URL"))
end
deliveries = orders * updates
results = [1, 2, 4, 8].map do |workers|
  ShopifyFixture.run do |run|
    if pg
      pg.execute("DROP TABLE IF EXISTS #{ShopifyLedger::Postgres::TABLES.join(', ')}")
      pg.migrate
    end
    run.with_endpoint do
      orders.times do |index|
        number = 1000 + index
        order = "gid://shopify/Order/#{number}"
        transaction = ShopifyFixture.transaction("gid://shopify/OrderTransaction/#{number}", "SALE", "1.00")
        run.admin.arrange(ShopifyFixture::ALPHA, "OrderPayments", order,
                          { data: { order: { id: order, transactions: [transaction],
                                             transactionsCount: { count: 1, precision: "EXACT" } } } }) { sleep latency }
      end
      updates.times do |update|
        orders.times do |index|
          number = 1000 + index
          run.deliver("bench-#{number}-#{update}", payload: { id: number, admin_graphql_api_id: "gid://shopify/Order/#{number}" })
        end
      end
    end
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    executable = pg ? "bin/shopify-pg-worker" : "bin/shopify-worker"
    processes = Array.new(workers) do |machine|
      ENV["SHOPIFY_LEDGER_WORKER_ID"] = "machine-#{machine}"
      run.spawn(executable, "--drain")
    end
    outputs = processes.map do |stdin, stdout, stderr, waiter|
      stdin.close
      output = stdout.read
      errors = stderr.read
      raise "worker failed: #{output}#{errors}" unless waiter.value.success?

      JSON.parse(output)
    end
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
    {
      workers: workers,
      fetch_outcomes: outputs.sum { |output| output.fetch("processed") },
      deliveries_completed: (pg || run).then { |db| db.respond_to?(:migrate) ? db.get_first_value("SELECT SUM(processed) FROM inbox") : db.read("SELECT SUM(processed) FROM inbox").first.first },
      admin_fetches: run.admin.requests.count { |request| request.fetch("operation") == "OrderPayments" },
      seconds: elapsed.round(2),
      deliveries_per_second: (deliveries / elapsed).round(1),
      net: (pg ? ShopifyLedger::Payments.summary(pg, ShopifyFixture::ALPHA) : run.summary.fetch("totals")).first.fetch("net")
    }
  end
end
puts JSON.pretty_generate(backend: backend, orders: orders, updates_per_order: updates, deliveries: deliveries, admin_latency_ms: (latency * 1000).round, runs: results)
