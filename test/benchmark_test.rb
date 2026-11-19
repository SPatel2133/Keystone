require "minitest/test"
require_relative "../benchmark/ledger_benchmark"
require_relative "support/ledger_process"

class LedgerBenchmarkTest < Minitest::Test
  def test_reports_nearest_rank_latency_and_wall_time_throughput
    latencies = 20.downto(1).map { |milliseconds| milliseconds * 1_000_000 }
    metrics = LedgerBenchmark.batch_metrics(latencies, 500_000_000)
    assert_equal 20, metrics.fetch(:samples)
    assert_equal 500.0, metrics.fetch(:elapsed_ms)
    assert_equal 40.0, metrics.fetch(:acknowledgments_per_second)
    assert_equal 10.0, metrics.fetch(:p50_ms)
    assert_equal 19.0, metrics.fetch(:p95_ms)
  end

  def test_smoke_run_measures_distinct_cli_and_in_process_batches_in_scratch
    Dir.mktmpdir do |dir|
      caller_db = LedgerProcess.database(dir)
      LedgerProcess.response(dir, LedgerProcess.deliver(1, -7))
      original = File.binread(caller_db)
      entry = File.join(LedgerProcess::ROOT, "bin", "benchmark")
      out, err, status = Open3.capture3(entry, "--smoke", chdir: dir)
      assert status.success?, err
      data = JSON.parse(out)
      ordered = data.fetch("ordered")
      count = ordered.fetch("samples")
      expected = { "cursor" => count, "balance" => count, "unique_events" => count }
      assert_equal expected, ordered.fetch("final_state")
      assert_equal expected, data.fetch("identical_retries").fetch("final_state")
      storage = ordered.fetch("storage")
      growth = storage.fetch("final_bytes").values.sum - storage.fetch("baseline_bytes").values.sum
      assert_equal growth, storage.fetch("growth_bytes")
      assert_equal growth.fdiv(count), storage.fetch("bytes_per_unique_event")
      cli = data.fetch("cli_ordered")
      assert_equal cli.fetch("samples"), cli.fetch("final_state").fetch("unique_events")
      gap = data.fetch("gap_closure")
      assert_equal gap.fetch("buffered_events_applied") + 1, gap.fetch("final_state").fetch("cursor")
      assert_equal original, File.binread(caller_db)
    end
  end
end
