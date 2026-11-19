require "minitest/test"
require_relative "support/scenarios"
require_relative "../lib/event_consumer/ledger"

class LedgerTest < Minitest::Test
  MAX_INT64 = 9_223_372_036_854_775_807
  MIN_INT64 = -9_223_372_036_854_775_808
  STATE = { op: "state" }.freeze
  INVALID = { "error" => "invalid_request" }.freeze

  def test_actual_process_harness
    CrashHarness::SEAMS.each do |seam|
      record = CrashHarness.probe(seam)
      assert_strict(record.fetch("expected"), record.fetch("observed"), seam)
    end
  end

  def test_before_commit
    Scenarios.crash("before_commit", verify: method(:assert_strict))
  end

  def test_after_commit_before_ack
    Scenarios.crash("after_commit_before_ack", verify: method(:assert_strict))
  end

  def test_busy_when_another_writer_holds_reservation
    Scenarios.contention("write", verify: method(:assert_strict))
  end

  def test_busy_at_commit_with_an_independent_reader
    Scenarios.contention("read", verify: method(:assert_strict))
  end

  def test_all_six_permutations_against_independent_oracle
    [[1, 5], [2, 0], [3, -2]].permutation.each do |feed|
      Dir.mktmpdir("ledger-permutation-") do |directory|
        oracle = PrefixOracle.new
        ask(directory, STATE, oracle.state)
        feed.each do |sequence, delta|
          ask(directory, LedgerProcess.deliver(sequence, delta), oracle.receive(sequence, delta))
          ask(directory, STATE, oracle.state)
        end
        assert_strict({ "cursor" => 3, "balance" => 3 }, oracle.state, feed.inspect)
      end
    end
  end

  def test_ordering_disagrees_with_naive_last_seen
    record = Scenarios.ordering(verify: method(:assert_strict))
    assert_strict({ "cursor" => 3, "balance" => 6 }, record.fetch("ledger"), "correct prefix")
    assert_strict({ "last_seen" => 3, "balance" => 7 }, record.fetch("naive_observed"), "naive sum")
  end

  def test_duplicate_conflict_and_gap_draining
    Dir.mktmpdir("ledger-gap-") do |directory|
      oracle = PrefixOracle.new
      [[3, 2], [4, -1], [2, 0], [3, 2]].each do |sequence, delta|
        ask(directory, LedgerProcess.deliver(sequence, delta), oracle.receive(sequence, delta))
      end
      pending = { "events" => [[2, 0], [3, 2], [4, -1]], "checkpoint" => [0, "0"] }
      assert_strict(pending, LedgerProcess.snapshot(directory), "pending rows")
      ask(directory, LedgerProcess.deliver(3, 9), oracle.receive(3, 9))
      assert_strict(pending, LedgerProcess.snapshot(directory), "pending conflict")

      ask(directory, LedgerProcess.deliver(1, 5), oracle.receive(1, 5))
      ask(directory, LedgerProcess.deliver(3, 2), oracle.receive(3, 2))
      ask(directory, LedgerProcess.deliver(2, 0), oracle.receive(2, 0))
      applied = { "events" => [[1, 5], [2, 0], [3, 2], [4, -1]], "checkpoint" => [4, "6"] }
      assert_strict(applied, LedgerProcess.snapshot(directory), "applied rows")
      CrashHarness::SEAMS.each do |seam|
        ask(directory, LedgerProcess.deliver(3, 9, hook: seam),
            oracle.receive(3, 9), entry: LedgerProcess::HOOK_ENTRY)
        assert_strict(applied, LedgerProcess.snapshot(directory), "applied conflict with #{seam}")
      end
    end
  end

  def test_invalid_inputs_do_not_create_or_mutate_storage
    invalid_requests = [
      "", "null", "[]", "27", "{", '{"op":"state"} {"op":"state"}',
      '/*comment*/{"op":"state"}', '{"op":"state"}/*comment*/', '{"op":"state",}',
      '{"op":"state","op":"state"}', '{"op":"state","\u006fp":"state"}',
      '{"op":"deliver","seq":01,"delta":0}', '{"op":"deliver","seq":+1,"delta":0}',
      "{\"op\":\"sta\x00te\"}", "{\"op\":\"\xff\"}".b,
      {}, { op: "other" }, { op: 1 }, { op: "state", seq: 1 },
      { op: "deliver" }, { op: "deliver", seq: 1 }, { op: "deliver", delta: 1 },
      LedgerProcess.deliver(1, 0, extra: 0),
      *[0, -1, MAX_INT64 + 1, 1.0, "1", nil, true, [], {}].map { |seq| LedgerProcess.deliver(seq, 0) },
      *[MIN_INT64 - 1, MAX_INT64 + 1, 0.0, "0", nil, false, [], {}].map { |delta| LedgerProcess.deliver(1, delta) },
      '{"op":"deliver","seq":1e0,"delta":0}',
      *CrashHarness::SEAMS.map { |seam| LedgerProcess.deliver(1, 9, hook: seam) }
    ]
    invalid_hooks = [
      LedgerProcess.deliver(1, 9, hook: "unknown"),
      LedgerProcess.deliver(1, 9, hook: nil),
      LedgerProcess.deliver(1, 9, hook: 1),
      { op: "state", hook: "before_commit" },
      LedgerProcess.deliver(1, 9, hook: "before_commit", extra: 1),
      LedgerProcess.deliver(0, 9, hook: "after_commit_before_ack")
    ]

    Dir.mktmpdir("ledger-invalid-") do |directory|
      verify_invalid = lambda do
        invalid_requests.each { |request| ask(directory, request, INVALID) }
        invalid_hooks.each { |request| ask(directory, request, INVALID, entry: LedgerProcess::HOOK_ENTRY) }
      end
      verify_invalid.call
      assert_empty Dir.children(directory)
      ask(directory, LedgerProcess.deliver(1, 5), { "status" => "accepted", "seq" => 1, "cursor" => 1, "balance" => 5 })
      ask(directory, LedgerProcess.deliver(3, 2), { "status" => "accepted", "seq" => 3, "cursor" => 1, "balance" => 5 })
      original = LedgerProcess.snapshot(directory)
      bytes = File.binread(LedgerProcess.database(directory))
      verify_invalid.call
      assert_strict(original, LedgerProcess.snapshot(directory), "storage after invalid requests")
      assert_equal bytes, File.binread(LedgerProcess.database(directory))
    end
  end

  def test_exact_balance_above_and_below_signed_64_bit_after_reopen
    [MAX_INT64, MIN_INT64].each do |delta|
      Dir.mktmpdir("ledger-exact-") do |directory|
        ask(directory, LedgerProcess.deliver(1, delta), { "status" => "accepted", "seq" => 1, "cursor" => 1, "balance" => delta })
        total = 2 * delta
        ask(directory, LedgerProcess.deliver(2, delta), { "status" => "accepted", "seq" => 2, "cursor" => 2, "balance" => total })
        ask(directory, STATE, { "cursor" => 2, "balance" => total })
        assert_strict({ "events" => [[1, delta], [2, delta]], "checkpoint" => [2, total.to_s] },
                      LedgerProcess.snapshot(directory), "raw integer deltas and decimal balance")
      end
    end
  end

  def test_sparse_maximum_sequence_remains_pending
    Dir.mktmpdir("ledger-sparse-") do |directory|
      ask(directory, LedgerProcess.deliver(MAX_INT64, MIN_INT64),
          { "status" => "accepted", "seq" => MAX_INT64, "cursor" => 0, "balance" => 0 })
      ask(directory, STATE, { "cursor" => 0, "balance" => 0 })
      assert_strict({ "events" => [[MAX_INT64, MIN_INT64]], "checkpoint" => [0, "0"] },
                    LedgerProcess.snapshot(directory), "sparse durable row")
    end
  end

  def test_cursor_guard_never_looks_up_a_key_above_maximum
    result = EventConsumer::Ledger.drain(MAX_INT64 - 1, 7) do |next_sequence|
      assert_equal MAX_INT64, next_sequence
      0
    end
    assert_equal [MAX_INT64, 7], result
    assert_equal [MAX_INT64, 7], EventConsumer::Ledger.drain(MAX_INT64, 7) { flunk "looked up past maximum" }
  end

  def test_valid_escaped_string_and_json_whitespace
    Dir.mktmpdir("ledger-escaped-") do |directory|
      ask(directory, " \t\r\n" + '{"\u006fp":"st\u0061te"}' + "\r\n", { "cursor" => 0, "balance" => 0 })
    end
  end

  def test_incompatible_storage_fails_without_acknowledgment
    Dir.mktmpdir("ledger-incompatible-") do |directory|
      path = LedgerProcess.database(directory)
      SQLite3::Database.new(path) { |db| db.execute("CREATE TABLE events (id TEXT)") }
      original = File.binread(path)
      stdout, stderr, status = LedgerProcess.run(directory, LedgerProcess.deliver(1, 5))
      refute status.success?
      assert status.exited?, status.inspect
      assert_empty stdout
      assert_match(/incompatible ledger schema/, stderr)
      assert_equal original, File.binread(path)
    end
  end

  def test_absolute_launchers_keep_ledgers_in_independent_directories
    Dir.mktmpdir("ledger-one-") do |one|
      Dir.mktmpdir("ledger-two-") do |two|
        ask(one, LedgerProcess.deliver(1, 5), { "status" => "accepted", "seq" => 1, "cursor" => 1, "balance" => 5 })
        ask(two, STATE, { "cursor" => 0, "balance" => 0 }, entry: LedgerProcess::HOOK_ENTRY)
        ask(two, LedgerProcess.deliver(1, -7), { "status" => "accepted", "seq" => 1, "cursor" => 1, "balance" => -7 },
            entry: LedgerProcess::HOOK_ENTRY)
        ask(one, STATE, { "cursor" => 1, "balance" => 5 })
        assert File.file?(LedgerProcess.database(one))
        assert File.file?(LedgerProcess.database(two))
      end
    end
  end

  private

  def ask(directory, request, expected, entry: LedgerProcess::ENTRY)
    actual = LedgerProcess.response(directory, request, entry: entry)
    assert_strict(expected, actual, "#{entry} #{request.inspect}")
  end

  def assert_strict(expected, observed, context)
    # eql? checks nested key sets and types, including the difference between 2 and 2.0.
    assert expected.eql?(observed), "#{context}\nExpected: #{expected.inspect}\nObserved: #{observed.inspect}"
  end
end
