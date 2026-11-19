require "json"
require "socket"
require_relative "admin"
require_relative "config"
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
      "CREATE INDEX IF NOT EXISTS payment_events_by_shop_order ON payment_events (shop, order_id)"
    ].freeze

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

      def migrate
        SCHEMA.each { |statement| @connection.exec(statement) }
        self
      end
    end

    def self.receive(db, shop:, webhook_id:, topic:, order_id:)
      db.execute(<<~SQL, [shop, webhook_id, topic, order_id, Time.now.to_i]).any?
        INSERT INTO inbox (shop, webhook_id, topic, order_id, received_at) VALUES (?, ?, ?, ?, ?)
        ON CONFLICT (shop, webhook_id) DO NOTHING RETURNING id
      SQL
    end

    class Worker
      LEASE = 60

      def initialize(config, db, owner: "#{Socket.gethostname}:#{Process.pid}")
        @config = config
        @db = db
        @owner = owner
      end

      def drain
        counts = { "processed" => 0, "retry" => 0, "parked" => 0 }
        loop do
          outcome = run_once
          return counts.merge("status" => "idle") if outcome == "idle"

          counts[outcome] += 1
        end
      end

      def run_once(before_commit: nil, after_commit: nil)
        claim = claim_next or return "idle"
        id, shop, order_id, attempts, webhook_id = claim
        fence = @db.get_first_value("SELECT MAX(id) FROM inbox WHERE shop = ? AND order_id = ?", [shop, order_id])
        raise Admin::Error, "Delivery shop is no longer configured" unless @config.shop?(shop)

        entries = Payments.entries(Admin.new(@config, shop).order_transactions(order_id))
        applied = @db.transaction do |db|
          # Applying is idempotent; this lock only stops two completions racing.
          next false unless db.get_first_value("SELECT processed FROM inbox WHERE id = ? FOR UPDATE", [id]) == 0

          Payments.apply(db, shop, order_id, entries, source: "delivery:#{webhook_id}")
          db.execute(<<~SQL, [Time.now.to_i, shop, order_id, fence])
            UPDATE inbox SET processed = 1, processed_at = ?, last_error = NULL, claimed_by = NULL, claimed_until = NULL
            WHERE shop = ? AND order_id = ? AND processed = 0 AND parked_at IS NULL AND id <= ?
          SQL
          before_commit&.call
          true
        end
        after_commit&.call if applied
        "processed"
      rescue Admin::Error, Payments::Error => error
        defer(id, attempts, error)
      end

      private

      def claim_next
        now = Time.now.to_i
        @db.get_first_row(<<~SQL, [@owner, now + LEASE, now, now])
          UPDATE inbox SET claimed_by = ?, claimed_until = ?
          WHERE id = (
            SELECT id FROM inbox
            WHERE processed = 0 AND parked_at IS NULL AND next_attempt_at <= ?
              AND (claimed_until IS NULL OR claimed_until <= ?)
            ORDER BY id LIMIT 1
            FOR UPDATE SKIP LOCKED
          )
          RETURNING id, shop, order_id, attempts, webhook_id
        SQL
      end

      def defer(id, attempts, error)
        now = Time.now.to_i
        parked = attempts + 1 >= @config.max_attempts
        @db.execute(<<~SQL, [error.message, now + [2**(attempts + 1), 60].min, parked ? now : nil, id])
          UPDATE inbox SET attempts = attempts + 1, last_error = ?, next_attempt_at = ?, parked_at = ?,
                           claimed_by = NULL, claimed_until = NULL
          WHERE id = ? AND processed = 0
        SQL
        Log.event(parked ? "delivery_parked" : "delivery_retry", delivery: id, error: "#{error.class}: #{error.message}")
        parked ? "parked" : "retry"
      end
    end

    def self.cli(arguments, **hooks)
      url = ENV.fetch("SHOPIFY_LEDGER_POSTGRES_URL") { raise ArgumentError, "set SHOPIFY_LEDGER_POSTGRES_URL" }
      db = Database.new(url).migrate
      owner = ENV.fetch("SHOPIFY_LEDGER_WORKER_ID", "#{Socket.gethostname}:#{Process.pid}")
      worker = Worker.new(Config.load, db, owner: owner)
      case arguments
      in ["--once"]
        status = worker.run_once(**hooks)
        puts JSON.generate(status: status)
        %w[retry parked].include?(status) ? 1 : 0
      in ["--drain"] if hooks.empty?
        puts JSON.generate(worker.drain)
        0
      in ["summary", String => shop]
        puts JSON.generate(shop: shop, totals: Payments.summary(db, shop))
        0
      else
        raise ArgumentError, "usage: bin/shopify-pg-worker --once | --drain | summary SHOP"
      end
    ensure
      db&.close
    end
  end
end
