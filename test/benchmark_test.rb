require "minitest/test"
require_relative "../benchmark/ledger_benchmark"

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
end
