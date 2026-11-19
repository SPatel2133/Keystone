#!/usr/bin/env ruby
# Drains DELIVERIES webhooks with 1, 2, 4 and 8 concurrent `bin/shopify-worker
# --drain` processes against the local fake Admin API, which delays each order
# fetch by LATENCY_MS. Usage: ruby benchmark/shopify_drain.rb [DELIVERIES] [LATENCY_MS]
require_relative "../lib/event_consumer/bundle"
require_relative "../test/support/shopify_scenarios"

deliveries = Integer(ARGV.fetch(0, "200"))
latency = Integer(ARGV.fetch(1, "50")) / 1000.0
results = [1, 2, 4, 8].map do |workers|
  ShopifyFixture.run do |run|
    run.with_endpoint do
      deliveries.times do |index|
        number = 1000 + index
        order = "gid://shopify/Order/#{number}"
        transaction = ShopifyFixture.transaction("gid://shopify/OrderTransaction/#{number}", "SALE", "1.00")
        run.admin.arrange(ShopifyFixture::ALPHA, "OrderPayments", order,
                          { data: { order: { id: order, transactions: [transaction],
                                             transactionsCount: { count: 1, precision: "EXACT" } } } }) { sleep latency }
        run.deliver("bench-#{number}", payload: { id: number, admin_graphql_api_id: order })
      end
    end
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    outputs = Array.new(workers) { run.spawn("bin/shopify-worker", "--drain") }.map do |stdin, stdout, stderr, waiter|
      stdin.close
      output = stdout.read
      stderr.read
      raise "worker failed: #{output}" unless waiter.value.success?

      JSON.parse(output)
    end
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
    {
      workers: workers,
      processed: outputs.sum { |output| output.fetch("processed") },
      admin_fetches: run.admin.requests.count { |request| request.fetch("operation") == "OrderPayments" },
      seconds: elapsed.round(2),
      deliveries_per_second: (deliveries / elapsed).round(1),
      net: run.summary.fetch("totals").first.fetch("net")
    }
  end
end
puts JSON.pretty_generate(deliveries: deliveries, admin_latency_ms: (latency * 1000).round, runs: results)
