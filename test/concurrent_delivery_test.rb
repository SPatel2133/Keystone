require "minitest/test"
require_relative "support/scenarios"

class ConcurrentDeliveryTest < Minitest::Test
  BUSY = { "error" => "busy", "retryable" => true }.freeze
  REPLAY = "bin/check -n /concurrent_delivery/".freeze

  def test_concurrent_delivery
    Dir.mktmpdir("ledger-concurrent-") do |dir|
      seed = [3, 0]
      race = [[4, -11], [2, 7], [3, 0], [3, 99], [1, 9]]
      assert_equal PrefixOracle.new.receive(*seed), LedgerProcess.response(dir, LedgerProcess.deliver(*seed))
      initial = { "events" => [seed], "checkpoint" => [0, "0"] }
      SQLite3::Database.new(LedgerProcess.database(dir)) do |writer|
        writer.execute("BEGIN IMMEDIATE")
        assert_equal Array.new(race.length, BUSY), deliver_batch(dir, race, now + 15), REPLAY
        assert_equal initial, LedgerProcess.snapshot(dir), REPLAY
        writer.execute("ROLLBACK")
      end
      assert_equal initial, LedgerProcess.snapshot(dir), REPLAY

      outstanding = race
      receipts = {}
      deadline = now + 15
      10.times do
        responses = deliver_batch(dir, outstanding, deadline)
        outstanding.zip(responses).each { |op, reply| receipts[op] = reply unless reply == BUSY }
        outstanding = outstanding.reject { |op| receipts.key?(op) }
        break if outstanding.empty?
      end
      assert_empty outstanding, REPLAY
      # Scheduling is unspecified. All receipts together must describe one
      # serial ordering of the deliveries, including their intermediate totals.
      consistent = race.permutation.any? do |order|
        oracle = PrefixOracle.new
        oracle.receive(*seed)
        order.all? { |op| oracle.receive(*op).eql?(receipts.fetch(op)) }
      end
      assert consistent, "No serial order explains #{receipts.inspect}. Replay: #{REPLAY}"
      assert_equal({ "events" => [[1, 9], [2, 7], [3, 0], [4, -11]], "checkpoint" => [4, "5"] },
                   LedgerProcess.snapshot(dir), REPLAY)
    end
  end

  private

  def now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def deliver_batch(dir, operations, deadline)
    children = []
    operations.each do
      children << Open3.popen3(CrashHarness::CLEAN_ENV, [LedgerProcess::ENTRY, LedgerProcess::ENTRY], chdir: dir)
    end
    # All public executables exist before the first one receives its stdin EOF.
    children.zip(operations).each do |(input, _, _, _), op|
      input.write(JSON.generate(LedgerProcess.deliver(*op)))
      input.close
    end
    children.map do |_, output, error, wait|
      raise "consumer timed out. Replay: #{REPLAY}" unless wait.join([0, deadline - now].max)

      stderr = error.read
      raise "consumer #{wait.value.inspect}, stderr=#{stderr.inspect}. Replay: #{REPLAY}" unless wait.value.success? && stderr.empty?
      JSON.parse(output.read)
    end
  ensure
    children&.each do |input, output, error, wait|
      if wait.alive?
        begin
          Process.kill("KILL", wait.pid)
        rescue Errno::ESRCH
          # The child exited between checking its status and cleanup.
        end
      end
      wait.join
      [input, output, error].each { |io| io.close unless io.closed? }
    end
  end
end
