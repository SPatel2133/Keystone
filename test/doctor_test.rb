require "minitest/test"
require "tmpdir"
require_relative "support/ledger_process"

class DoctorTest < Minitest::Test
  ENTRY = File.join(LedgerProcess::ROOT, "bin", "doctor")

  def doctor(directory)
    out, err, status = CrashHarness.capture(directory, ENTRY)
    assert status.success?, err
    assert_empty err
    out
  end

  def test_missing_and_uninitialized_databases
    Dir.mktmpdir do |dir|
      assert_match(/ledger\.sqlite3.*missing|missing.*ledger\.sqlite3/i, doctor(dir))
      assert_empty Dir.children(dir)
      File.write(LedgerProcess.database(dir), "")
      assert_match(/uninitialized/i, doctor(dir))
      assert_equal "", File.binread(LedgerProcess.database(dir))
    end
  end

  def test_stalled_stream_and_maximum_sparse_key_leave_storage_unchanged
    Dir.mktmpdir do |dir|
      LedgerProcess.response(dir, { op: "state" })
      assert_includes doctor(dir), "Stream is caught up."
      LedgerProcess.response(dir, LedgerProcess.deliver(1, 10))
      LedgerProcess.response(dir, LedgerProcess.deliver(3, -2))
      path = LedgerProcess.database(dir)
      before = File.binread(path)
      assert_equal "Applied cursor: 1\nAdjustment balance: 10\nPending events: 1\nWaiting for scan 2; scan 3 is already stored.\n", doctor(dir)
      assert_equal before, File.binread(path)
      assert_equal ["ledger.sqlite3"], Dir.children(dir)
      max = (2**63) - 1
      LedgerProcess.response(dir, LedgerProcess.deliver(max, 3))
      assert_includes doctor(dir), "Pending events: 2"
      LedgerProcess.response(dir, LedgerProcess.deliver(2, -3))
      assert_includes doctor(dir), "Waiting for scan 4; scan #{max} is already stored."
    end
  end

  def test_uncommitted_checkpoint_and_event_are_invisible
    Dir.mktmpdir do |dir|
      LedgerProcess.response(dir, LedgerProcess.deliver(1, 10))
      LedgerProcess.response(dir, LedgerProcess.deliver(3, -2))
      db = SQLite3::Database.new(LedgerProcess.database(dir))
      db.execute("BEGIN IMMEDIATE")
      db.execute("INSERT INTO events (seq, delta) VALUES (2, -3)")
      db.execute("UPDATE checkpoint SET cursor = 3, balance = '5' WHERE id = 1")
      assert_includes doctor(dir), "Applied cursor: 1\nAdjustment balance: 10\nPending events: 1"
      db.execute("COMMIT")
      assert_includes doctor(dir), "Applied cursor: 3\nAdjustment balance: 5\nPending events: 0\nStream is caught up."
    ensure
      db&.close
    end
  end

  def test_wal_database_is_left_alone_even_when_sidecars_are_absent
    Dir.mktmpdir do |dir|
      LedgerProcess.response(dir, { op: "state" })
      path = LedgerProcess.database(dir)
      SQLite3::Database.new(path) { |db| db.execute("PRAGMA journal_mode=WAL") }
      before = File.binread(path)
      assert_equal ["ledger.sqlite3"], Dir.children(dir)
      out, err, status = CrashHarness.capture(dir, ENTRY)
      refute status.success?
      assert_empty out
      assert_includes err, "WAL mode"
      assert_equal ["ledger.sqlite3"], Dir.children(dir)
      assert_equal before, File.binread(path)
    end
  end

  def test_incompatible_database_exits_without_a_report
    Dir.mktmpdir do |dir|
      SQLite3::Database.new(LedgerProcess.database(dir)) { |db| db.execute("CREATE TABLE events (seq)") }
      out, err, status = CrashHarness.capture(dir, ENTRY)
      refute status.success?
      assert_empty out
      assert_includes err, "incompatible ledger schema"
    end
  end
end
