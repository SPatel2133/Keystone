require "minitest/autorun"
require "json"
require "open3"
require "tmpdir"
require "sqlite3"

class ShopifyStorageTest < Minitest::Test
  SHOP = "alpha.myshopify.com"
  SUMMARY = File.expand_path("../../bin/shopify-summary", __dir__)

  def setup
    @directory = Dir.mktmpdir("shopify-schema")
    @path = File.join(@directory, "store.sqlite3")
    config = File.join(@directory, "config.json")
    File.write(config, JSON.generate(database: @path, secret: "test", shops: { SHOP => { token: "test" } }))
    @env = { "SHOPIFY_LEDGER_CONFIG" => config }
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def summary
    Open3.capture3(@env, SUMMARY, SHOP)
  end

  def test_foreign_database_cannot_publish_a_duplicate_payment_as_revenue
    SQLite3::Database.new(@path) do |db|
      db.execute("CREATE TABLE checkpoints (shop, synced_through)")
      db.execute("CREATE TABLE transactions (shop, transaction_id, currency, kind, amount)")
      2.times { db.execute("INSERT INTO transactions VALUES (?, ?, ?, ?, ?)", [SHOP, "sale-1", "CAD", "SALE", "100.00"]) }
    end
    original = File.binread(@path)

    stdout, stderr, status = summary
    refute status.success?
    assert_empty stdout
    assert_includes stderr, "incompatible Shopify ledger schema"
    assert_equal original, File.binread(@path)
  end

  def test_previous_schema_upgrades_without_changing_payments_or_progress
    assert summary.last.success?
    SQLite3::Database.new(@path) do |db|
      db.execute("DROP TABLE reconciliation_starts")
      db.execute("INSERT INTO transactions VALUES (?, ?, ?, ?, ?, ?)", [SHOP, "sale-1", "order-1", "CAD", "SALE", "100.00"])
      db.execute("INSERT INTO checkpoints VALUES (?, ?)", [SHOP, "2026-11-18T00:00:00Z"])
    end

    stdout, stderr, status = summary
    assert status.success?, stderr
    assert_equal "100.00", JSON.parse(stdout).fetch("totals").fetch(0).fetch("net")
    SQLite3::Database.new(@path) do |db|
      assert_empty db.execute("SELECT * FROM reconciliation_starts")
      assert_equal [[SHOP, "2026-11-18T00:00:00Z"]], db.execute("SELECT * FROM checkpoints")
    end
  end
end
