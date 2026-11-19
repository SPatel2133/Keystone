require "minitest/test"
require "open3"
require "tmpdir"
require_relative "../lib/event_consumer/ledger"
require_relative "support/ledger_process"

class MaintenanceTest < Minitest::Test
  ENTRY = File.join(LedgerProcess::ROOT, "bin", "maintain")

  def maintain(dir, path = LedgerProcess.database(dir))
    Open3.capture3(ENTRY, path, chdir: dir)
  end

  def check_history(dir)
    assert_equal({ "status" => "duplicate", "seq" => 1, "cursor" => 1, "balance" => 10 },
                 LedgerProcess.response(dir, LedgerProcess.deliver(1, 10)))
    assert_equal({ "error" => "conflict", "seq" => 1 },
                 LedgerProcess.response(dir, LedgerProcess.deliver(1, -99)))
  end

  def check_vacuum(free_pages:)
    Dir.mktmpdir do |dir|
      path = LedgerProcess.database(dir)
      LedgerProcess.response(dir, LedgerProcess.deliver(1, 10))
      LedgerProcess.response(dir, LedgerProcess.deliver(3, -2))
      if free_pages
        SQLite3::Database.new(path) do |db|
          db.execute("CREATE TABLE ballast (data BLOB)")
          db.execute("INSERT INTO ballast VALUES (zeroblob(1048576))")
          db.execute("DROP TABLE ballast")
        end
      end
      expected = { "events" => [[1, 10], [3, -2]], "checkpoint" => [1, "10"] }
      assert_equal expected, LedgerProcess.snapshot(dir)
      check_history(dir)
      before = File.size(path)
      stdout, stderr, status = maintain(dir)
      assert status.success?, stderr
      sizes = JSON.parse(stdout)
      assert_equal before, sizes.fetch("before").fetch("main_file_bytes")
      assert_equal File.size(path), sizes.fetch("after").fetch("main_file_bytes")
      assert_equal 0, sizes.fetch("after").fetch("free_pages")
      if free_pages
        assert_operator sizes.fetch("before").fetch("free_pages"), :>, 0
        assert_operator File.size(path), :<, before
      else
        assert_equal 0, sizes.fetch("before").fetch("free_pages")
        assert_equal before, File.size(path)
      end
      assert_equal expected, LedgerProcess.snapshot(dir)
      check_history(dir)
    end
  end

  def test_reclaims_free_pages_and_preserves_authoritative_history
    check_vacuum(free_pages: true)
  end

  def test_fully_live_fixture_has_no_reclaimable_pages
    check_vacuum(free_pages: false)
  end

  def test_refuses_missing_path_foreign_database_and_active_writer
    Dir.mktmpdir do |dir|
      path = LedgerProcess.database(dir)
      _, _, status = maintain(dir)
      refute status.success?
      refute File.exist?(path)
      foreign = File.join(dir, "unrelated.sqlite3")
      SQLite3::Database.new(foreign) { |db| db.execute("CREATE TABLE unrelated (value)") }
      before = File.binread(foreign)
      _, stderr, status = maintain(dir, foreign)
      refute status.success?
      assert_includes stderr, "incompatible ledger schema"
      assert_equal before, File.binread(foreign)

      LedgerProcess.response(dir, LedgerProcess.deliver(1, 10))
      snapshot = LedgerProcess.snapshot(dir)
      SQLite3::Database.new(path) do |writer|
        writer.execute("BEGIN IMMEDIATE")
        _, stderr, status = maintain(dir)
        refute status.success?
        assert_includes stderr, "busy"
        writer.execute("ROLLBACK")
      end
      assert_equal snapshot, LedgerProcess.snapshot(dir)
    end
  end

  def test_pruning_an_applied_row_would_destroy_historical_conflict_detection
    Dir.mktmpdir do |dir|
      LedgerProcess.response(dir, LedgerProcess.deliver(1, 10))
      check_history(dir)
      # Deliberately corrupt only this disposable fixture.
      SQLite3::Database.new(LedgerProcess.database(dir)) { |db| db.execute("DELETE FROM events WHERE seq = 1") }
      receipt = LedgerProcess.response(dir, LedgerProcess.deliver(1, -99))
      assert_equal "accepted", receipt.fetch("status")
      assert_equal({ "events" => [[1, -99]], "checkpoint" => [1, "10"] }, LedgerProcess.snapshot(dir))
    end
  end
end
