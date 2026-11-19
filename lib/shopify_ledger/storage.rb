require "sqlite3"

module ShopifyLedger
  class Storage
    LEGACY_TABLES = {
      "inbox" => <<~SQL.chomp,
        CREATE TABLE inbox (
          id INTEGER PRIMARY KEY,
          shop TEXT NOT NULL,
          webhook_id TEXT NOT NULL,
          topic TEXT NOT NULL,
          order_id TEXT NOT NULL,
          processed INTEGER NOT NULL DEFAULT 0 CHECK (processed IN (0, 1)),
          attempts INTEGER NOT NULL DEFAULT 0 CHECK (attempts >= 0),
          next_attempt_at INTEGER NOT NULL DEFAULT 0,
          last_error TEXT,
          UNIQUE (shop, webhook_id)
        )
      SQL
      "transactions" => <<~SQL.chomp,
        CREATE TABLE transactions (
          shop TEXT NOT NULL,
          transaction_id TEXT NOT NULL,
          order_id TEXT NOT NULL,
          currency TEXT NOT NULL,
          kind TEXT NOT NULL CHECK (kind IN ('SALE', 'CAPTURE', 'REFUND')),
          amount TEXT NOT NULL CHECK (typeof(amount) = 'text'),
          PRIMARY KEY (shop, transaction_id)
        )
      SQL
      "checkpoints" => <<~SQL.chomp,
        CREATE TABLE checkpoints (
          shop TEXT PRIMARY KEY NOT NULL,
          synced_through TEXT NOT NULL
        )
      SQL
    }.freeze
    STARTS_TABLE = <<~SQL.chomp.freeze
      CREATE TABLE reconciliation_starts (
        shop TEXT PRIMARY KEY NOT NULL,
        window_start TEXT NOT NULL
      )
    SQL
    OPERATIONS = [
      "ALTER TABLE inbox ADD COLUMN received_at INTEGER",
      "ALTER TABLE inbox ADD COLUMN last_attempt_at INTEGER",
      "ALTER TABLE inbox ADD COLUMN processed_at INTEGER",
      "ALTER TABLE inbox ADD COLUMN parked_at INTEGER",
      "ALTER TABLE inbox ADD COLUMN requeues INTEGER NOT NULL DEFAULT 0 CHECK (requeues >= 0)",
      "ALTER TABLE inbox ADD COLUMN claimed_by INTEGER",
      "ALTER TABLE inbox ADD COLUMN claimed_until INTEGER",
      "ALTER TABLE transactions ADD COLUMN recorded_at INTEGER",
      "ALTER TABLE transactions ADD COLUMN source TEXT",
      <<~SQL.chomp,
        CREATE TABLE reconciliation_runs (
          id INTEGER PRIMARY KEY,
          shop TEXT NOT NULL,
          window_start TEXT NOT NULL,
          window_end TEXT NOT NULL,
          status TEXT NOT NULL CHECK (status IN ('running', 'failed', 'completed')),
          started_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL,
          finished_at INTEGER,
          attempts INTEGER NOT NULL DEFAULT 1 CHECK (attempts >= 1),
          pages INTEGER NOT NULL DEFAULT 0 CHECK (pages >= 0),
          orders INTEGER NOT NULL DEFAULT 0 CHECK (orders >= 0),
          cursor TEXT,
          last_error TEXT
        )
      SQL
      "CREATE UNIQUE INDEX one_open_run_per_shop ON reconciliation_runs (shop) WHERE status <> 'completed'",
      "CREATE INDEX inbox_by_shop ON inbox (shop, processed, parked_at)",
    # Worker selection must not scan parked or processed history.
    "CREATE INDEX inbox_eligible ON inbox (id, next_attempt_at) WHERE processed = 0 AND parked_at IS NULL",
      "CREATE INDEX transactions_by_shop_order ON transactions (shop, order_id)"
    ].freeze
    # Every transaction Shopify reports, with its latest status. Only SUCCESS
    # sales, captures and refunds move money, and those also go to transactions.
    PAYMENT_DOMAIN = [
      "ALTER TABLE transactions ADD COLUMN presentment_currency TEXT",
      "ALTER TABLE transactions ADD COLUMN presentment_amount TEXT",
      "ALTER TABLE transactions ADD COLUMN parent_transaction_id TEXT",
      <<~SQL.chomp,
        CREATE TABLE payment_events (
          shop TEXT NOT NULL,
          transaction_id TEXT NOT NULL,
          order_id TEXT NOT NULL,
          kind TEXT NOT NULL,
          status TEXT NOT NULL,
          currency TEXT NOT NULL,
          amount TEXT NOT NULL,
          presentment_currency TEXT NOT NULL,
          presentment_amount TEXT NOT NULL,
          parent_transaction_id TEXT,
          first_seen_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL,
          PRIMARY KEY (shop, transaction_id)
        )
      SQL
      "CREATE INDEX payment_events_by_shop_order ON payment_events (shop, order_id)"
    ].freeze
    # Each step upgrades the catalog left by the previous one. A new database
    # runs every step, so fresh and upgraded files share one table definition.
    MIGRATIONS = [
      [*LEGACY_TABLES.values,
       "CREATE INDEX inbox_ready ON inbox (processed, next_attempt_at, id)",
       "CREATE INDEX transactions_by_shop_currency ON transactions (shop, currency)"],
      [STARTS_TABLE],
      OPERATIONS,
      PAYMENT_DOMAIN
    ].freeze

    def self.catalogs
      @catalogs ||= begin
        db = SQLite3::Database.new(":memory:")
        [{}] + MIGRATIONS.map do |statements|
          statements.each { |statement| db.execute(statement) }
          catalog(db).freeze
        end
      ensure
        db&.close
      end.freeze
    end

    def self.catalog(db)
      db.execute(<<~SQL).to_h
        SELECT name, sql FROM sqlite_master
        WHERE type IN ('table', 'view') AND name NOT GLOB 'sqlite_*'
      SQL
    end

    # Webhooks keep the short default so a locked file returns 503 well within
    # Shopify's delivery timeout; background workers can afford to wait.
    def initialize(path, busy_timeout: 250)
      @path = path
      @busy_timeout = busy_timeout
    end

    def connect
      db = SQLite3::Database.new(@path)
      db.busy_timeout(@busy_timeout)
      prepare_schema(db) unless self.class.catalog(db) == self.class.catalogs.last
      yield db
    ensure
      db&.close
    end

    private

    def prepare_schema(db)
      # A concurrent process may have initialized or upgraded the file meanwhile.
      # DDL is transactional in SQLite, so a failed upgrade leaves the prior version.
      self.class.transaction(db) do
        version = self.class.catalogs.index(self.class.catalog(db))
        raise ArgumentError, "incompatible Shopify ledger schema" unless version

        MIGRATIONS.drop(version).flatten.each { |statement| db.execute(statement) }
      end
    end

    # The SQLite side of the store interface that Reconciliation and Status use;
    # Postgres::Store is the other side.
    Store = Struct.new(:path) do
      def connect(&block) = Storage.new(path).connect(&block)
      def transaction(db, &block) = Storage.transaction(db, &block)

      # One read transaction, so every count in a report comes from one snapshot.
      def read(db)
        db.transaction(:deferred)
        yield
      ensure
        db.rollback if db.transaction_active?
      end
    end

    def self.transaction(db, before_commit: nil, after_commit: nil)
      db.execute("BEGIN IMMEDIATE")
      begin
        result = yield
        before_commit&.call
        db.execute("COMMIT")
        after_commit&.call
        result
      ensure
        db.execute("ROLLBACK") if db.transaction_active?
      end
    end
  end
end
