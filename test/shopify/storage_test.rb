require "minitest/autorun"
require "json"
require "open3"
require "tmpdir"
require "sqlite3"
require_relative "../../lib/event_consumer/bundle"
require_relative "../../lib/shopify_ledger/storage"

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

  def build_version(version)
    SQLite3::Database.new(@path) do |db|
      ShopifyLedger::Storage::MIGRATIONS.first(version).flatten.each { |statement| db.execute(statement) }
    end
  end

  def test_previous_schema_upgrades_without_changing_payments_or_progress
    build_version(2)
    SQLite3::Database.new(@path) do |db|
      db.execute("INSERT INTO transactions VALUES (?, ?, ?, ?, ?, ?)", [SHOP, "sale-1", "order-1", "CAD", "SALE", "100.00"])
      db.execute("INSERT INTO checkpoints VALUES (?, ?)", [SHOP, "2026-11-18T00:00:00Z"])
      db.execute("INSERT INTO inbox (shop, webhook_id, topic, order_id, attempts, last_error) VALUES (?, ?, ?, ?, ?, ?)",
                 [SHOP, "old-delivery", "orders/updated", "order-1", 3, "Admin API returned HTTP 503"])
    end

    stdout, stderr, status = summary
    assert status.success?, stderr
    assert_equal "100.00", JSON.parse(stdout).fetch("totals").fetch(0).fetch("net")
    SQLite3::Database.new(@path) do |db|
      assert_equal ShopifyLedger::Storage.catalogs.last, ShopifyLedger::Storage.catalog(db)
      assert_empty db.execute("SELECT * FROM reconciliation_starts")
      assert_empty db.execute("SELECT * FROM reconciliation_runs")
      assert_equal [[SHOP, "2026-11-18T00:00:00Z"]], db.execute("SELECT * FROM checkpoints")
      # Pre-upgrade rows keep their facts; unknown provenance stays NULL.
      assert_equal [["sale-1", "100.00", nil, nil]], db.execute("SELECT transaction_id, amount, recorded_at, source FROM transactions")
      assert_equal [[0, 3, nil, nil, 0]], db.execute("SELECT processed, attempts, received_at, parked_at, requeues FROM inbox")
    end
  end

  def test_first_schema_version_upgrades_through_every_step
    build_version(1)
    SQLite3::Database.new(@path) do |db|
      db.execute("INSERT INTO transactions VALUES (?, ?, ?, ?, ?, ?)", [SHOP, "refund-1", "order-1", "CAD", "REFUND", "25.00"])
    end
    stdout, stderr, status = summary
    assert status.success?, stderr
    assert_equal "-25.00", JSON.parse(stdout).fetch("totals").fetch(0).fetch("net")
    SQLite3::Database.new(@path) do |db|
      assert_equal ShopifyLedger::Storage.catalogs.last, ShopifyLedger::Storage.catalog(db)
    end
  end

  def test_failed_upgrade_rolls_back_to_the_previous_version_and_can_be_retried
    build_version(2)
    SQLite3::Database.new(@path) do |db|
      db.execute("INSERT INTO transactions VALUES (?, ?, ?, ?, ?, ?)", [SHOP, "sale-1", "order-1", "CAD", "SALE", "100.00"])
      # The last upgrade statement creates this index name, so the upgrade fails after
      # every column and table has already been added inside its transaction.
      db.execute("CREATE INDEX transactions_by_shop_order ON checkpoints (shop)")
    end
    version_two = ShopifyLedger::Storage.catalogs[2]

    _stdout, stderr, status = summary
    refute status.success?
    assert_match(/already exists/, stderr)
    SQLite3::Database.new(@path) do |db|
      assert_equal version_two, ShopifyLedger::Storage.catalog(db)
      assert_equal [["sale-1", "100.00"]], db.execute("SELECT transaction_id, amount FROM transactions")
      db.execute("DROP INDEX transactions_by_shop_order")
    end

    stdout, stderr, status = summary
    assert status.success?, stderr
    assert_equal "100.00", JSON.parse(stdout).fetch("totals").fetch(0).fetch("net")
  end
end
