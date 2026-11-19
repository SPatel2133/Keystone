require "bigdecimal"
require "fileutils"
require "json"
require "set"
require_relative "shopify_fixture"
%w[config storage inbox payments worker reconciliation deliveries backup maintenance move_shop].each do |name|
  require_relative "../../lib/shopify_ledger/#{name}"
end

# Randomized crash testing of the Shopify ledger against a reference model.
# A seed expands into a list of abstract operations (deliveries, workers that
# crash at commit seams, Admin API faults, order mutations, reconciliation with
# failing pages, operator retries, backups, maintenance). The fake Admin API is
# the ground truth; invariants are checked after every step, and a final settle
# phase must make the ledger equal the ground truth exactly.
module ShopifyFuzz
  include ShopifyFixture

  class Failure < StandardError; end
  class Crash < StandardError; end

  SHOPS = [ALPHA, BETA].freeze
  CURRENCIES = %w[CAD USD].freeze
  PAGE_SIZE = 3
  # The fake Admin API answers a "timeout" fault after this, past the client's read timeout.
  TIMEOUT = 0.2
  WEIGHTS = {
    "deliver" => 18, "duplicate" => 6, "worker" => 16, "crash_before_commit" => 3, "crash_after_commit" => 3,
    "orphan_claim" => 3, "admin_fault" => 6, "mutate" => 16, "advance_time" => 5, "operator_retry" => 3,
    "reconcile" => 5, "reconcile_failing_page" => 3, "backup" => 1, "maintain" => 1, "complete_pending" => 4,
    "admin_stale_read" => 3, "move_shop" => 3
  }.freeze
  PROCESS_WEIGHTS = { "drain_processes" => 2, "kill_mid_fetch" => 2 }.freeze

  def self.generate(seed, steps, processes: false)
    random = Random.new(seed)
    weights = processes ? WEIGHTS.merge(PROCESS_WEIGHTS) : WEIGHTS
    bag = weights.flat_map { |op, weight| [op] * weight }
    [{ "op" => "setup", "a" => 1 + random.rand(20) }] +
      Array.new(steps) { { "op" => bag[random.rand(bag.size)], "a" => random.rand(2**30), "b" => random.rand(2**30), "c" => random.rand(2**30) } }
  end

  # Runs one operation list; returns nil on success or a failure hash.
  def self.execute(ops, backend: :sqlite)
    (backend == :postgres ? PostgresExecution : Execution).new(ops).call
    nil
  rescue Failure => error
    { "message" => error.message }
  end

  # Drops operations while the failure still reproduces: halving chunks first
  # for speed, then one operation at a time until nothing more can go.
  def self.shrink(ops, backend: :sqlite)
    current = ops
    chunk = [(current.size - 1) / 2, 1].max
    loop do
      index = 1
      changed = false
      while index < current.size
        candidate = current[0...index] + (current[(index + chunk)..] || [])
        if execute(candidate, backend: backend)
          current = candidate
          changed = true
        else
          index += chunk
        end
      end
      if chunk > 1
        chunk /= 2
      elsif !changed
        return current
      end
    end
  end

  def self.campaign(seed:, runs:, steps:, processes: false, directory: nil, shrink: true, backend: :sqlite)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    counts = Hash.new(0)
    failures = []
    runs.times do |index|
      run_seed = seed + index
      ops = generate(run_seed, steps, processes: processes)
      ops.drop(1).each { |op| counts[op["op"]] += 1 }
      failure = execute(ops, backend: backend)
      next unless failure

      minimal = shrink ? shrink(ops, backend: backend) : ops
      record = { "seed" => run_seed, "steps" => steps, "processes" => processes, "backend" => backend.to_s,
                 "failure" => failure, "minimized_failure" => execute(minimal, backend: backend), "ops" => minimal }
      if directory
        FileUtils.mkdir_p(directory)
        record["file"] = File.join(directory, "fuzz-failure-#{run_seed}.json")
        File.write(record["file"], JSON.pretty_generate(record))
      end
      failures << record
    end
    { "seed" => seed, "runs" => runs, "steps" => steps, "processes" => processes, "backend" => backend.to_s,
      "operations" => counts.sort.to_h,
      "failures" => failures, "seconds" => (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(2) }
  end
end

require_relative "shopify_fuzz/execution"
require_relative "shopify_fuzz/postgres_execution"
