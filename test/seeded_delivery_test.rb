require "minitest/test"
require_relative "support/scenarios"

class SeededDeliveryTest < Minitest::Test
  def test_seeded_delivery
    seeds = ENV.fetch("LEDGER_SEEDS", "17,83,211").split(",").map { |s| Integer(s, 10) }
    raise "supply 1 to 100 integer seeds" unless (1..100).cover?(seeds.size)

    seeds.each { |seed| exercise(seed) }
  end

  private

  def exercise(seed)
    rng = Random.new(seed)
    deltas = (1..9).to_h { |seq| [seq, rng.rand(-30..30)] }.merge(2 => -7, 4 => 0)
    # Every seed has a gap, a zero, a negative, an identical retry, a conflict,
    # and fresh events at both seams. The shuffled tail eventually fills every gap.
    schedule = [[4, 0], [4, 0], [4, 1], [2, -7, "before_commit"],
                [1, deltas.fetch(1), "after_commit_before_ack"]]
    tail = (3..9).map { |seq| [seq, deltas.fetch(seq)] }
    7.times do
      seq = rng.rand(1..9)
      tail << [seq, deltas.fetch(seq) + rng.rand(0..1)]
    end
    schedule.concat(tail.shuffle(random: rng))
    oracle = PrefixOracle.new
    rows = {}
    Dir.mktmpdir("ledger-seed-") do |dir|
      schedule.each_with_index do |(seq, delta, seam), index|
        @context = "seed=#{seed} step=#{index + 1} seq=#{seq} delta=#{delta} seam=#{seam.inspect}. " \
                   "Replay: LEDGER_SEEDS=#{seed} bin/check -n /seeded_delivery/"
        if seam
          request = LedgerProcess.deliver(seq, delta, hook: seam)
          observed = CrashHarness.observation(*LedgerProcess.run(dir, request, entry: LedgerProcess::HOOK_ENTRY))
          assert_equal CrashHarness.killed, observed, @context
          if seam == "after_commit_before_ack"
            oracle.receive(seq, delta)
            rows[seq] = delta
          end
          assert_snapshot(dir, oracle, rows)
        end
        expected = oracle.receive(seq, delta)
        rows[seq] = delta if expected["status"] == "accepted"
        actual = LedgerProcess.response(dir, LedgerProcess.deliver(seq, delta))
        assert expected.eql?(actual), "#{@context}\nExpected #{expected.inspect}; actual #{actual.inspect}"
        assert_snapshot(dir, oracle, rows)
      end
      assert_equal({ "cursor" => 9, "balance" => rows.values.sum }, oracle.state, @context)
    end
  rescue StandardError => error
    raise "#{@context}\n#{error.class}: #{error.message}"
  end

  def assert_snapshot(dir, oracle, rows)
    state = oracle.state
    expected = { "events" => rows.sort, "checkpoint" => [state.fetch("cursor"), state.fetch("balance").to_s] }
    assert_equal expected, LedgerProcess.snapshot(dir), @context
  end
end
