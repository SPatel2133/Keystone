#!/usr/bin/env ruby
# Measures worker selection and bin/shopify-status against a disposable inbox
# with a large parked and processed history. Usage: ruby benchmark/shopify_operations.rb [ROWS]
require_relative "../lib/event_consumer/bundle"
require_relative "../lib/shopify_ledger/config"
require_relative "../lib/shopify_ledger/storage"
require_relative "../lib/shopify_ledger/status"
require "json"
require "tmpdir"

rows = Integer(ARGV.fetch(0, "50000"))
SHOP = "bench.myshopify.com".freeze
SELECT = "SELECT id FROM inbox %s WHERE processed = 0 AND parked_at IS NULL AND next_attempt_at <= ? ORDER BY id LIMIT 1".freeze

def mean_ms(repeats)
  start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  repeats.times { yield }
  ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) / repeats * 1000).round(3)
end

Dir.mktmpdir do |dir|
  path = File.join(dir, "bench.sqlite3")
  result = { rows_parked: rows, rows_processed: rows, rows_eligible: 1 }
  ShopifyLedger::Storage.new(path).connect do |db|
    db.transaction
    insert = "INSERT INTO inbox (shop, webhook_id, topic, order_id, attempts, processed, next_attempt_at, parked_at, received_at) " \
             "VALUES (?, ?, 'orders/updated', 'gid://shopify/Order/1', ?, ?, 1, ?, 1)"
    rows.times { |i| db.execute(insert, [SHOP, "parked-#{i}", 12, 0, 1]) }
    rows.times { |i| db.execute(insert, [SHOP, "done-#{i}", 1, 1, nil]) }
    db.execute(insert, [SHOP, "live", 0, 0, nil])
    db.commit
    now = Time.now.to_i
    { "worker_select" => "INDEXED BY inbox_eligible", "without_partial_index" => "INDEXED BY inbox_ready" }.each do |name, hint|
      sql = format(SELECT, hint)
      result[name] = {
        plan: db.execute("EXPLAIN QUERY PLAN #{sql}", [now]).map(&:last),
        mean_ms: mean_ms(50) { db.execute(sql, [now]) }
      }
    end
  end
  config = ShopifyLedger::Config.new({ "database" => path, "secret" => "x", "shops" => { SHOP => { "token" => "t" } } }, dir)
  result["status_report_mean_ms"] = mean_ms(5) { ShopifyLedger::Status.new(config).report([SHOP]) }
  puts JSON.pretty_generate(result)
end
