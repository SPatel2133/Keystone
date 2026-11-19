require "etc"
require "json"
require "open3"
require "tmpdir"
require_relative "../lib/event_consumer/ledger"

class LedgerBenchmark
  LEDGER_CLI = File.expand_path("../bin/ledger", __dir__)
  DATABASE = EventConsumer::Ledger::FILE_NAME
  FULL = { unique: 100_000, buffered: 10_000, cli: 20 }.freeze
  SMOKE = { unique: 50, buffered: 20, cli: 3 }.freeze

  def initialize(full: false)
    @mode = full ? "full" : "smoke"
    @counts = full ? FULL : SMOKE
    @ledger = EventConsumer::Ledger.new
  end

  def run
    result = {
      command: "bin/benchmark --#{@mode}",
      environment: environment,
      timing: {
        clock: "CLOCK_MONOTONIC (nanoseconds); nearest-rank p50/p95",
        in_process: "One writer, one Ledger#call per request: open, BEGIN IMMEDIATE, schema check, deliver, COMMIT, close. Input construction, receipt verification and storage inspection are outside the timed batch.",
        cli: "One fresh bin/ledger child per request. Includes spawn, Ruby and Bundler startup, JSON input/output, SQLite transaction and process exit.",
        storage: "Main database plus -journal, -wal and -shm after all connections close, before and after ordered ingestion. No explicit WAL checkpoint.",
        fixture: "Scratch databases, schema initialized, delta +1 for every sequence."
      }
    }
    in_scratch do
      result[:sqlite_settings] = sqlite_settings
      baseline = file_sizes
      count = @counts.fetch(:unique)
      requests = (1..count).map { |seq| request(seq) }
      result[:ordered] = batch(requests, status: "accepted") { |req| @ledger.call(req) }
      final = file_sizes
      growth = final.values.sum - baseline.values.sum
      result[:ordered][:storage] = {
        baseline_bytes: baseline, final_bytes: final, growth_bytes: growth,
        bytes_per_unique_event: growth.fdiv(count)
      }
      result[:identical_retries] = batch(requests, status: "duplicate") { |req| @ledger.call(req) }
    end

    result[:gap_closure] = in_scratch { gap_closure }
    result[:cli_ordered] = in_scratch do
      requests = (1..@counts.fetch(:cli)).map { |seq| request(seq) }
      # Serialize inputs before timing. Child parsing and serialization are included.
      inputs = requests.to_h { |req| [req.fetch("seq"), JSON.generate(req)] }
      batch(requests, status: "accepted", cli: true) do |req|
        Open3.capture3([LEDGER_CLI, LEDGER_CLI], stdin_data: inputs.fetch(req.fetch("seq")))
      end
    end
    result
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

  def request(seq)
    { "op" => "deliver", "seq" => seq, "delta" => 1 }
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

  def verify_state(cursor, count)
    row = nil
    SQLite3::Database.new(DATABASE, readonly: true) do |db|
      row = db.get_first_row("SELECT cursor, balance, (SELECT COUNT(*) FROM events) FROM checkpoint WHERE id = 1")
    end
    expected = [cursor, cursor.to_s, count]
    raise "Expected durable state #{expected.inspect}, got #{row.inspect}" unless row == expected

    { cursor: row[0], balance: Integer(row[1], 10), unique_events: row[2] }
  end

  def verify_receipt(receipt, status, seq, cursor)
    expected = { status: status, seq: seq, cursor: cursor, balance: cursor }
    raise "Expected #{expected.inspect}, got #{receipt.inspect}" unless expected == receipt
  end

  def batch(requests, status:, cli: false)
    receipts = Array.new(requests.length)
    latencies = Array.new(requests.length)
    start = now_ns
    requests.each_with_index do |req, index|
      before = now_ns
      receipts[index] = yield(req)
      latencies[index] = now_ns - before
    end
    elapsed = now_ns - start
    receipts.each_with_index do |receipt, index|
      if cli
        stdout, stderr, exit_status = receipt
        raise "CLI failed: #{exit_status.inspect}, #{stderr.inspect}" unless exit_status.success? && stderr.empty?
        receipt = JSON.parse(stdout, symbolize_names: true)
      end
      seq = index + 1
      verify_receipt(receipt, status, seq, status == "duplicate" ? requests.size : seq)
    end
    self.class.batch_metrics(latencies, elapsed).merge(final_state: verify_state(requests.size, requests.size))
  end

  def gap_closure
    buffered = @counts.fetch(:buffered)
    (2..buffered + 1).each do |seq|
      verify_receipt(@ledger.call(request(seq)), "accepted", seq, 0)
    end
    pending = verify_state(0, buffered)
    closing = request(1)
    before = now_ns
    receipt = @ledger.call(closing)
    elapsed = now_ns - before
    verify_receipt(receipt, "accepted", 1, buffered + 1)
    {
      samples: 1, elapsed_ms: elapsed / 1_000_000.0, before_close: pending,
      buffered_events_applied: buffered, final_state: verify_state(buffered + 1, buffered + 1)
    }
  end

  def file_sizes
    ["", "-journal", "-wal", "-shm"].to_h do |suffix|
      path = DATABASE + suffix
      [path, File.exist?(path) ? File.size(path) : 0]
    end
  end

  def sqlite_settings
    SQLite3::Database.new(DATABASE, readonly: true) do |db|
      return {
        journal_mode: db.get_first_value("PRAGMA journal_mode"),
        synchronous: db.get_first_value("PRAGMA synchronous"),
        page_size: db.get_first_value("PRAGMA page_size")
      }
    end
  end

  def sysctl(name)
    output, _, status = Open3.capture3("/usr/sbin/sysctl", "-n", name)
    output.strip if status.success?
  end

  def environment
    host = Etc.uname
    cpu, memory = case host.fetch(:sysname)
                  when "Darwin"
                    [sysctl("machdep.cpu.brand_string"),
                     Integer(sysctl("hw.memsize"), exception: false)]
                  when "Linux"
                    [File.read("/proc/cpuinfo")[/^(?:model name|Hardware)\s*:\s*(.+)$/, 1],
                     Integer(File.read("/proc/meminfo")[/^MemTotal:\s*(\d+)/, 1]) * 1024]
                  end
    {
      machine: host.fetch(:machine), cpu: cpu, memory_bytes: memory,
      os: host.fetch(:sysname), kernel: host.fetch(:release),
      ruby: RUBY_DESCRIPTION, sqlite: SQLite3::SQLITE_VERSION, sqlite3_gem: SQLite3::VERSION,
      bundler: Bundler::VERSION
    }
  end
end
