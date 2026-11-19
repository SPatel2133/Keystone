require_relative "ledger_process"
require_relative "prefix_oracle"

module Scenarios
  FEED = [[1, 5], [3, 2], [2, -1]].freeze
  INITIAL = { "events" => [[1, 5], [3, 2]], "checkpoint" => [1, "5"] }.freeze
  COMPLETE = { "events" => [[1, 5], [2, -1], [3, 2]], "checkpoint" => [3, "6"] }.freeze
  CRASH_FIXTURES = {
    "before_commit" => [INITIAL, "accepted"],
    "after_commit_before_ack" => [COMPLETE, "duplicate"]
  }.freeze

  def self.verify!(expected, observed, detail)
    return if expected.eql?(observed)

    raise "#{detail}: expected #{expected.inspect}, observed #{observed.inspect}"
  end

  def self.ordering(verify: method(:verify!))
    Dir.mktmpdir("ledger-ordering-") do |directory|
      oracle = PrefixOracle.new
      steps = FEED.map do |sequence, delta|
        expected = oracle.receive(sequence, delta)
        observed = LedgerProcess.response(directory, LedgerProcess.deliver(sequence, delta))
        verify.call(expected, observed, "ordering seq=#{sequence} delta=#{delta}")
        { "seq" => sequence, "delta" => delta, "expected" => expected, "observed" => observed }
      end
      observed_state = LedgerProcess.response(directory, { op: "state" })
      verify.call(oracle.state, observed_state, "ordering final state")

      last_seen = 0
      balance = 0
      FEED.each do |sequence, delta|
        next if sequence <= last_seen

        last_seen = sequence
        balance += delta
      end
      expected_naive = { "last_seen" => 3, "balance" => 7 }
      naive = { "last_seen" => last_seen, "balance" => balance }
      verify.call(expected_naive, naive, "naive last-seen comparison")
      {
        "type" => "ordering",
        "steps" => steps,
        "oracle" => oracle.state,
        "ledger" => observed_state,
        "naive_expected" => expected_naive,
        "naive_observed" => naive
      }
    end
  end

  def self.crash(seam, verify: method(:verify!))
    durable_before_retry, retry_status = CRASH_FIXTURES.fetch(seam)
    expected = {
      "child" => CrashHarness.killed,
      "before_retry" => durable_before_retry,
      "retry" => { "status" => retry_status, "seq" => 2, "cursor" => 3, "balance" => 6 },
      "after_retry" => COMPLETE,
      "conflict" => { "error" => "conflict", "seq" => 3 },
      "after_conflict" => COMPLETE
    }

    Dir.mktmpdir("ledger-crash-") do |directory|
      oracle = PrefixOracle.new
      FEED.first(2).each do |sequence, delta|
        receipt = LedgerProcess.response(directory, LedgerProcess.deliver(sequence, delta))
        verify.call(oracle.receive(sequence, delta), receipt, "seed #{seam} seq=#{sequence}")
      end
      verify.call(INITIAL, LedgerProcess.snapshot(directory), "seed rows for #{seam}")

      request = LedgerProcess.deliver(2, -1, hook: seam)
      stdout, stderr, status = LedgerProcess.run(directory, request, entry: LedgerProcess::HOOK_ENTRY)
      observed = { "child" => CrashHarness.observation(stdout, stderr, status) }
      verify.call(expected.fetch("child"), observed.fetch("child"), "killed child for #{seam}")
      observed["before_retry"] = LedgerProcess.snapshot(directory)
      verify.call(durable_before_retry, observed.fetch("before_retry"), "durable rows before retry for #{seam}")

      observed["retry"] = LedgerProcess.response(directory, LedgerProcess.deliver(2, -1))
      observed["after_retry"] = LedgerProcess.snapshot(directory)
      observed["conflict"] = LedgerProcess.response(directory, LedgerProcess.deliver(3, 9))
      observed["after_conflict"] = LedgerProcess.snapshot(directory)
      verify.call(expected, observed, "recovery for #{seam}")
      { "type" => "crash_recovery", "seam" => seam, "expected" => expected, "observed" => observed }
    end
  end

  def self.contention(reservation, verify: method(:verify!))
    Dir.mktmpdir("ledger-busy-") do |directory|
      sequence_one = LedgerProcess.response(directory, LedgerProcess.deliver(1, 5))
      verify.call({ "status" => "accepted", "seq" => 1, "cursor" => 1, "balance" => 5 }, sequence_one, "busy seed")
      initial = { "events" => [[1, 5]], "checkpoint" => [1, "5"] }
      request = LedgerProcess.deliver(2, -1)
      observed = {}
      SQLite3::Database.new(LedgerProcess.database(directory)) do |holder|
        if reservation == "write"
          holder.execute("BEGIN IMMEDIATE")
        else
          # A reader in default rollback-journal mode lets the writer reserve,
          # then blocks its COMMIT from taking the exclusive lock.
          verify.call("delete", holder.get_first_value("PRAGMA journal_mode"), "reader journal mode")
          holder.execute("BEGIN")
          holder.get_first_row("SELECT cursor, balance FROM checkpoint")
        end
        observed["busy"] = LedgerProcess.response(directory, request)
        observed["under_lock"] = LedgerProcess.snapshot(directory)
        holder.execute("ROLLBACK")
      end
      observed["after_release"] = LedgerProcess.snapshot(directory)
      observed["retry"] = LedgerProcess.response(directory, request)
      observed["after_retry"] = LedgerProcess.snapshot(directory)

      expected = {
        "busy" => { "error" => "busy", "retryable" => true },
        "under_lock" => initial,
        "after_release" => initial,
        "retry" => { "status" => "accepted", "seq" => 2, "cursor" => 2, "balance" => 4 },
        "after_retry" => { "events" => [[1, 5], [2, -1]], "checkpoint" => [2, "4"] }
      }
      verify.call(expected, observed, "busy with #{reservation} reservation")
      { "type" => "contention", "reservation" => reservation, "expected" => expected, "observed" => observed }
    end
  end
end
