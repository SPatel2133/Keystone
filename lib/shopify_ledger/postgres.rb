require "json"
require "securerandom"
require "socket"
require "uri"
require_relative "admin"
require_relative "config"
require_relative "inbox"
require_relative "log"
require_relative "payments"

module ShopifyLedger
  # PostgreSQL backend for the inbox and payment ledger, for workers on several
  # machines. Claims use FOR UPDATE SKIP LOCKED plus a lease, not PIDs, because
  # a PID means nothing on another host. Payments.apply/observe/review run
  # unchanged through Database, which speaks the subset of the sqlite3 API they use.
  module Postgres
    SCHEMA = [
      <<~SQL,
        CREATE TABLE IF NOT EXISTS inbox (
          id BIGSERIAL PRIMARY KEY,
          shop TEXT NOT NULL,
          webhook_id TEXT NOT NULL,
          topic TEXT NOT NULL,
          order_id TEXT NOT NULL,
          processed INTEGER NOT NULL DEFAULT 0 CHECK (processed IN (0, 1)),
          attempts INTEGER NOT NULL DEFAULT 0,
          next_attempt_at BIGINT NOT NULL DEFAULT 0,
          last_error TEXT,
          received_at BIGINT NOT NULL,
          processed_at BIGINT,
          parked_at BIGINT,
          claimed_by TEXT,
          claimed_until BIGINT,
          UNIQUE (shop, webhook_id),
          CHECK (NOT (processed = 1 AND parked_at IS NOT NULL))
        )
      SQL
      "CREATE INDEX IF NOT EXISTS inbox_eligible ON inbox (id) WHERE processed = 0 AND parked_at IS NULL",
      "ALTER TABLE inbox ADD COLUMN IF NOT EXISTS last_attempt_at BIGINT",
      "ALTER TABLE inbox ADD COLUMN IF NOT EXISTS requeues INTEGER NOT NULL DEFAULT 0",
      <<~SQL,
        CREATE TABLE IF NOT EXISTS transactions (
          shop TEXT NOT NULL,
          transaction_id TEXT NOT NULL,
          order_id TEXT NOT NULL,
          currency TEXT NOT NULL,
          kind TEXT NOT NULL CHECK (kind IN ('SALE', 'CAPTURE', 'REFUND')),
          amount TEXT NOT NULL,
          recorded_at BIGINT,
          source TEXT,
          presentment_currency TEXT,
          presentment_amount TEXT,
          parent_transaction_id TEXT,
          PRIMARY KEY (shop, transaction_id)
        )
      SQL
      <<~SQL,
        CREATE TABLE IF NOT EXISTS payment_events (
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
          first_seen_at BIGINT NOT NULL,
          updated_at BIGINT NOT NULL,
          PRIMARY KEY (shop, transaction_id)
        )
      SQL
      "CREATE INDEX IF NOT EXISTS payment_events_by_shop_order ON payment_events (shop, order_id)",
      "CREATE TABLE IF NOT EXISTS checkpoints (shop TEXT PRIMARY KEY, synced_through TEXT NOT NULL)",
      "CREATE TABLE IF NOT EXISTS reconciliation_starts (shop TEXT PRIMARY KEY, window_start TEXT NOT NULL)",
      <<~SQL,
        CREATE TABLE IF NOT EXISTS reconciliation_runs (
          id BIGSERIAL PRIMARY KEY,
          shop TEXT NOT NULL,
          window_start TEXT NOT NULL,
          window_end TEXT NOT NULL,
          status TEXT NOT NULL CHECK (status IN ('running', 'failed', 'completed')),
          started_at BIGINT NOT NULL,
          updated_at BIGINT NOT NULL,
          finished_at BIGINT,
          attempts INTEGER NOT NULL DEFAULT 1 CHECK (attempts >= 1),
          pages INTEGER NOT NULL DEFAULT 0 CHECK (pages >= 0),
          orders INTEGER NOT NULL DEFAULT 0 CHECK (orders >= 0),
          cursor TEXT,
          last_error TEXT
        )
      SQL
      "CREATE UNIQUE INDEX IF NOT EXISTS one_open_run_per_shop ON reconciliation_runs (shop) WHERE status <> 'completed'"
    ].freeze
    TABLES = %w[inbox transactions payment_events checkpoints reconciliation_starts reconciliation_runs].freeze

    def self.scratch_schema_name
      "shopify_ledger_scratch_#{Process.pid}_#{SecureRandom.hex(4)}"
    end

    def self.scratch_url(url, schema)
      raise ArgumentError, "invalid PostgreSQL schema" unless schema.match?(/\A[a-z_][a-z0-9_]*\z/i)

      return "#{url} options='-csearch_path=#{schema}'" unless url.start_with?("postgres://", "postgresql://")

      separator = URI.parse(url).query.to_s.empty? ? "?" : "&"
      "#{url}#{separator}options=-csearch_path%3D#{schema}"
    end

    def self.load_driver
      require "pg"
    rescue LoadError
      raise LoadError, "the pg gem is not installed; run: bundle config set --local with postgres && bundle install"
    end

    class Database
      def initialize(url)
        Postgres.load_driver
        @connection = PG.connect(url)
        @connection.type_map_for_results = PG::BasicTypeMapForResults.new(@connection)
        @connection.exec("SET client_min_messages TO warning")
      end

      def execute(statement, parameters = [], &block)
        index = 0
        rows = @connection.exec_params(statement.gsub("?") { "$#{index += 1}" }, parameters).values
        block ? rows.each(&block) : rows
      end

      def get_first_row(statement, parameters = []) = execute(statement, parameters).first
      def get_first_value(statement, parameters = []) = get_first_row(statement, parameters)&.first
      def transaction(&block) = @connection.transaction { block.call(self) }
      def close = @connection.close
      def reset = @connection.reset

      def migrate
        @connection.transaction do
          @connection.exec("SELECT pg_advisory_xact_lock(7243105118)")
          SCHEMA.each { |statement| @connection.exec(statement) }
        end
        self
      end
    end

    # Returns true for a new delivery. A redelivery must name the same topic
    # and order, as with SQLite.
    # Lets Reconciliation run unchanged against PostgreSQL.
    class Store
      def initialize(db)
        @db = db
      end

      def connect = yield(@db)
      def transaction(db, &block) = db.transaction { block.call }

      def read(db)
        db.execute("BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY")
        yield
      ensure
        db.execute("ROLLBACK")
      end
    end

    def self.receive(db, shop:, webhook_id:, topic:, order_id:)
      inserted = db.execute(<<~SQL, [shop, webhook_id, topic, order_id, Time.now.to_i]).any?
        INSERT INTO inbox (shop, webhook_id, topic, order_id, received_at) VALUES (?, ?, ?, ?, ?)
        ON CONFLICT (shop, webhook_id) DO NOTHING RETURNING id
      SQL
      return true if inserted

      original = db.get_first_row("SELECT topic, order_id FROM inbox WHERE shop = ? AND webhook_id = ?", [shop, webhook_id])
      raise ShopifyLedger::Inbox::IdentityConflict unless original == [topic, order_id]

      false
    end

    # Webhook ingest into PostgreSQL. WEBrick serves requests on threads and a
    # PG connection is not thread-safe, so requests share one connection in turn.
    class Inbox
      def initialize(url)
        @db = Database.new(url).migrate
        @mutex = Mutex.new
      end

      def receive(shop:, webhook_id:, topic:, order_id:, after_commit: nil)
        inserted = @mutex.synchronize do
          Postgres.receive(@db, shop: shop, webhook_id: webhook_id, topic: topic, order_id: order_id)
        rescue PG::ConnectionBad, PG::UnableToSend
          # This delivery gets a 503 and is redelivered; the next one uses a fresh connection.
          begin
            @db.reset
          rescue PG::Error
            nil
          end
          raise
        end
        after_commit&.call if inserted
        inserted
      end
    end
  end
end

require_relative "postgres/worker"
require_relative "postgres/cli"
