require "minitest/test"
require_relative "support/ledger_process"

class InventoryDemoTest < Minitest::Test
  def test_warehouse_replay_and_caller_isolation
    Dir.mktmpdir("inventory caller ") do |caller_dir|
      LedgerProcess.response(caller_dir, LedgerProcess.deliver(1, -40))
      original = File.binread(LedgerProcess.database(caller_dir))
      files = Dir.children(caller_dir).sort

      entry = File.join(LedgerProcess::ROOT, "bin/inventory-demo")
      stdout, stderr, status = CrashHarness.capture(caller_dir, entry)
      assert status.success?, stderr
      assert_empty stderr
      assert_includes stdout, "Scan 3 (-2) accepted. Cursor 1, adjustment +10, 30 units on hand."
      assert_includes stdout, "Waiting for scan 2. Scan 3 is already stored."
      assert_includes stdout, "SIGKILL (9) before acknowledgment, 0 stdout bytes."
      assert_includes stdout, 'rows=[[1,10],[2,-3],[3,-2]] checkpoint=[3,"5"]'
      assert_includes stdout, 'Retry scan 2: {"status":"duplicate","seq":2,"cursor":3,"balance":5}'
      assert_includes stdout, "20 opening units + 5 adjustment units = 25 units on hand."
      assert_equal files, Dir.children(caller_dir).sort
      assert_equal original, File.binread(LedgerProcess.database(caller_dir))
    end
  end
end
