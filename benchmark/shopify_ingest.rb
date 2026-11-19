#!/usr/bin/env ruby
# Sends DELIVERIES signed webhooks from SENDERS concurrent threads while
# WORKERS `bin/shopify-worker --drain` loops write to the same SQLite file, and
# reports acknowledgment codes and latency. Usage:
#   ruby benchmark/shopify_ingest.rb [DELIVERIES] [SENDERS] [WORKERS]
require_relative "../lib/event_consumer/bundle"
require_relative "../test/support/shopify_scenarios"

deliveries = Integer(ARGV.fetch(0, "400"))
senders = Integer(ARGV.fetch(1, "8"))
workers = Integer(ARGV.fetch(2, "4"))

def percentile(sorted, fraction) = sorted[[(sorted.size * fraction).ceil - 1, 0].max]

result = ShopifyFixture.run do |run|
  deliveries.times do |index|
    order = "gid://shopify/Order/#{1000 + index}"
    run.admin.order([ShopifyFixture.transaction("gid://shopify/OrderTransaction/#{1000 + index}", "SALE", "1.00")], id: order)
  end
  run.with_endpoint do
    stop = false
    drains = Array.new(workers) do
      Thread.new do
        outcomes = Hash.new(0)
        until stop
          _stdout, _stderr, status = run.command("bin/shopify-worker", "--drain")
          outcomes[status.exitstatus] += 1
        end
        outcomes
      end
    end
    queue = Queue.new
    deliveries.times { |index| queue << index }
    queue.close
    samples = Queue.new
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    Array.new(senders) do
      Thread.new do
        while (index = queue.pop)
          number = 1000 + index
          payload = { id: number, admin_graphql_api_id: "gid://shopify/Order/#{number}" }
          loop do
            began = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            code = run.deliver("ingest-#{number}", payload: payload)
            samples << [code, Process.clock_gettime(Process::CLOCK_MONOTONIC) - began]
            break if code == 200 # Shopify retries anything else; so does this sender.
          end
        end
      end
    end.each(&:join)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
    stop = true
    drains.each(&:join)
    run.json("bin/shopify-worker", "--drain")
    all = Array.new(samples.size) { samples.pop }
    latencies = all.select { |code, _| code == 200 }.map { |_, seconds| seconds * 1000 }.sort
    {
      deliveries: deliveries, senders: senders, drain_workers: workers,
      responses: all.group_by(&:first).transform_values(&:size),
      ack_per_second: (deliveries / elapsed).round(1),
      ack_p50_ms: percentile(latencies, 0.5).round(2), ack_p95_ms: percentile(latencies, 0.95).round(2),
      ack_max_ms: latencies.last.round(2),
      stored: run.read("SELECT COUNT(*), SUM(processed) FROM inbox").first,
      transactions: run.read("SELECT COUNT(*) FROM transactions").first.first,
      net: run.summary.fetch("totals").first.fetch("net")
    }
  end
end
puts JSON.pretty_generate(result)
