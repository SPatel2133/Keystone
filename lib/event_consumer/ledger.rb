require "sqlite3"
require_relative "request"

module EventConsumer
  class Ledger
    FILE_NAME = "ledger.sqlite3".freeze
    BUSY_TIMEOUT_MS = 250

    SCHEMA = {
      "checkpoint" => <<~SQL.chomp,
        CREATE TABLE checkpoint (
          id INTEGER PRIMARY KEY CHECK (id = 1),
          cursor INTEGER NOT NULL CHECK (typeof(cursor) = 'integer' AND cursor >= 0),
          balance TEXT NOT NULL CHECK (typeof(balance) = 'text')
        )
      SQL
      "events" => <<~SQL.chomp
        CREATE TABLE events (
          seq INTEGER PRIMARY KEY CHECK (seq >= 1),
          delta INTEGER NOT NULL CHECK (typeof(delta) = 'integer')
        )
      SQL
    }.freeze

    def call(request, hooks = {})
      SQLite3::Database.new(FILE_NAME) do |db|
        db.busy_timeout(BUSY_TIMEOUT_MS)
        db.execute("BEGIN IMMEDIATE")
        initialize_storage(db)
        cursor, balance = read_checkpoint(db)

        response = if request.fetch("op") == "deliver"
                     deliver(db, request, cursor, balance)
                   else
                     { cursor: cursor, balance: balance }
                   end

        hook = hooks[request["hook"]] unless response.key?(:error)
        hook.call if hook && request["hook"] == "before_commit"
        db.execute("COMMIT")
        hook.call if hook && request["hook"] == "after_commit_before_ack"
        return response
      ensure
        db.execute("ROLLBACK") if db.transaction_active?
      end
    rescue SQLite3::BusyException, SQLite3::LockedException
      { error: "busy", retryable: true }
    end

    # The block looks up exactly one key at a time in the active transaction.
    def self.drain(cursor, balance)
      while cursor < MAX_INTEGER
        next_sequence = cursor + 1
        delta = yield(next_sequence)
        break if delta.nil?

        cursor = next_sequence
        balance += delta
      end
      [cursor, balance]
    end

    private

    def initialize_storage(db)
      schema = db.execute(<<~SQL)
        SELECT type, name, sql FROM sqlite_master
        WHERE name NOT GLOB 'sqlite_*'
        ORDER BY name
      SQL
      if schema.empty?
        SCHEMA.each_value { |definition| db.execute(definition) }
        db.execute("INSERT INTO checkpoint (id, cursor, balance) VALUES (?, ?, ?)", [1, 0, "0"])
      elsif schema != SCHEMA.map { |name, definition| ["table", name, definition] }
        raise "incompatible ledger schema"
      end
    end

    def read_checkpoint(db)
      stored = db.get_first_row("SELECT cursor, balance FROM checkpoint WHERE id = ?", [1])
      raise "missing ledger checkpoint" unless stored

      cursor, decimal = stored
      balance = Integer(decimal, 10)
      raise "invalid ledger balance" unless balance.to_s == decimal

      [cursor, balance]
    end

    def deliver(db, request, cursor, balance)
      sequence = request.fetch("seq")
      delta = request.fetch("delta")
      prior = db.get_first_value("SELECT delta FROM events WHERE seq = ?", [sequence])
      if prior
        return { error: "conflict", seq: sequence } unless prior == delta

        return { status: "duplicate", seq: sequence, cursor: cursor, balance: balance }
      end

      db.execute("INSERT INTO events (seq, delta) VALUES (?, ?)", [sequence, delta])
      cursor, balance = self.class.drain(cursor, balance) do |key|
        db.get_first_value("SELECT delta FROM events WHERE seq = ?", [key])
      end
      db.execute("UPDATE checkpoint SET cursor = ?, balance = ? WHERE id = ?", [cursor, balance.to_s, 1])
      { status: "accepted", seq: sequence, cursor: cursor, balance: balance }
    end
  end
end
