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
    TABLES = LEGACY_TABLES.merge("reconciliation_starts" => STARTS_TABLE).freeze

    def initialize(path)
      @path = path
    end

    def connect
      db = SQLite3::Database.new(@path)
      db.busy_timeout(250)
      prepare_schema(db) unless catalog(db) == TABLES
      yield db
    ensure
      db&.close
    end

    private

    def catalog(db)
      db.execute(<<~SQL).to_h
        SELECT name, sql FROM sqlite_master
        WHERE type IN ('table', 'view') AND name NOT GLOB 'sqlite_*'
      SQL
    end

    def prepare_schema(db)
      # A concurrent process may have initialized or upgraded the file meanwhile.
      self.class.transaction(db) do
        tables = catalog(db)
        if tables.empty?
          TABLES.each_value { |definition| db.execute(definition) }
          db.execute("CREATE INDEX inbox_ready ON inbox (processed, next_attempt_at, id)")
          db.execute("CREATE INDEX transactions_by_shop_currency ON transactions (shop, currency)")
        elsif tables == LEGACY_TABLES
          db.execute(STARTS_TABLE)
        elsif tables != TABLES
          raise ArgumentError, "incompatible Shopify ledger schema"
        end
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
