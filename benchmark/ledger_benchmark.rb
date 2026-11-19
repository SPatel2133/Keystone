require "etc"
require "json"
require "tmpdir"
require_relative "../lib/event_consumer/ledger"

class LedgerBenchmark
  SAMPLES = 1_000
  BUFFERED = 10_000

  def initialize
    @ledger = EventConsumer::Ledger.new
  end

  def run
    {
      command: "bin/benchmark",
      environment: environment,
      timing: {
        implementation: "EventConsumer::Ledger#call, one Ruby process, one writer",
        included: "SQLite open, BEGIN IMMEDIATE, schema check, delivery, COMMIT, close",
        excluded: "Ruby/Bundler startup, JSON parsing and output, fixture setup, final verification",
        clock: "CLOCK_MONOTONIC, nanoseconds",
        latency: "Time from method invocation to receipt return, nearest-rank percentiles",
        throughput: "Acknowledged requests divided by elapsed wall time of the timed loop",
        fixture: "All deltas are +1. Each workload uses its own scratch database with the schema initialized."
      },
      ordered: in_scratch { timed_batch(retry_existing: false) },
      identical_retries: in_scratch { timed_batch(retry_existing: true) },
      gap_closure: in_scratch { gap_closure }
    }
  end

  def self.batch_metrics(latencies_ns, elapsed_ns)
    sorted = latencies_ns.sort
    count = sorted.size
    {
      samples: count,
      elapsed_ms: elapsed_ns / 1_000_000.0,
      acknowledgments_per_second: count * 1_000_000_000.0 / elapsed_ns,
      p50_ms: sorted.fetch((count * 0.50).ceil - 1) / 1_000_000.0,
      p95_ms: sorted.fetch((count * 0.95).ceil - 1) / 1_000_000.0
    }
  end

  private

  def now_ns
    Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
  end

  def request(sequence)
    { "op" => "deliver", "seq" => sequence, "delta" => 1 }
  end

  def in_scratch
    Dir.mktmpdir("ledger-benchmark-") do |directory|
      Dir.chdir(directory) do
        @ledger.call("op" => "state")
        verify_state(0, 0)
        yield
      end
    end
  end

  def verify_state(cursor, event_count)
    db = SQLite3::Database.new(EventConsumer::Ledger::FILE_NAME, readonly: true)
    # One SQL statement reads the checkpoint and row count at the same instant.
    row = db.get_first_row(<<~SQL)
      SELECT cursor, balance, (SELECT COUNT(*) FROM events)
      FROM checkpoint WHERE id = 1
    SQL
    expected = [cursor, cursor.to_s, event_count]
    raise "Expected durable state #{expected.inspect}, got #{row.inspect}" unless row == expected

    { cursor: row[0], balance: Integer(row[1], 10), unique_events: row[2] }
  ensure
    db&.close
  end

  def verify_receipt(receipt, status, sequence, cursor)
    expected = { status: status, seq: sequence, cursor: cursor, balance: cursor }
    raise "Expected #{expected.inspect}, got #{receipt.inspect}" unless expected == receipt
  end

  def timed_batch(retry_existing:)
    requests = (1..SAMPLES).map { |seq| request(seq) }
    if retry_existing
      requests.each { |req| verify_receipt(@ledger.call(req), "accepted", req["seq"], req["seq"]) }
      verify_state(SAMPLES, SAMPLES)
    end

    receipts = Array.new(SAMPLES)
    latencies = Array.new(SAMPLES)
    start = now_ns
    requests.each_with_index do |req, index|
      before = now_ns
      receipt = @ledger.call(req)
      latencies[index] = now_ns - before
      receipts[index] = receipt
    end
    elapsed = now_ns - start

    receipts.each_with_index do |receipt, index|
      seq = index + 1
      verify_receipt(receipt, retry_existing ? "duplicate" : "accepted", seq, retry_existing ? SAMPLES : seq)
    end
    self.class.batch_metrics(latencies, elapsed).merge(final_state: verify_state(SAMPLES, SAMPLES))
  end

  def gap_closure
    (2..BUFFERED + 1).each do |seq|
      verify_receipt(@ledger.call(request(seq)), "accepted", seq, 0)
    end
    pending = verify_state(0, BUFFERED)
    closing = request(1)
    before = now_ns
    receipt = @ledger.call(closing)
    elapsed = now_ns - before
    verify_receipt(receipt, "accepted", 1, BUFFERED + 1)
    final = verify_state(BUFFERED + 1, BUFFERED + 1)
    {
      samples: 1, elapsed_ms: elapsed / 1_000_000.0, before_close: pending,
      buffered_events_applied: final.fetch(:cursor) - 1, final_state: final
    }
  end

  def environment
    host = Etc.uname
    db = SQLite3::Database.new(":memory:")
    sqlite_version = db.get_first_value("SELECT sqlite_version()")
    {
      machine: host.fetch(:machine), os: host.fetch(:sysname), kernel: host.fetch(:release),
      ruby: RUBY_DESCRIPTION, sqlite: sqlite_version, sqlite3_gem: SQLite3::VERSION,
      bundler: Bundler::VERSION, minitest: Gem.loaded_specs.fetch("minitest").version.to_s
    }
  ensure
    db&.close
  end
end
