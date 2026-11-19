require_relative "ledger"

module EventConsumer
  module Doctor
    def self.report(path = Ledger::FILE_NAME)
      # SQLite can create shared-memory sidecars for WAL readers. The original
      # ledger uses rollback journaling. Inspect the SQLite write/read version
      # bytes before opening a connection so WAL diagnostics stay non-mutating.
      header = File.binread(path, 20)
      if header&.start_with?("SQLite format 3\0") && [header.getbyte(18), header.getbyte(19)].include?(2)
        raise ArgumentError, "WAL mode is unsupported by read-only diagnostics"
      end
      db = SQLite3::Database.new(path, readonly: true)
      db.busy_timeout(Ledger::BUSY_TIMEOUT_MS)
      # Keep the schema check, checkpoint and pending-row query on one snapshot.
      db.execute("BEGIN DEFERRED")
      schema = db.execute(<<~SQL)
        SELECT type, name, sql FROM sqlite_master
        WHERE name NOT GLOB 'sqlite_*' ORDER BY name
      SQL
      return "Ledger is uninitialized." if schema.empty?
      expected = Ledger::SCHEMA.map { |name, definition| ["table", name, definition] }
      raise ArgumentError, "incompatible ledger schema" unless schema == expected

      checkpoint = db.get_first_row("SELECT cursor, balance FROM checkpoint WHERE id = 1")
      raise ArgumentError, "missing ledger checkpoint" unless checkpoint
      cursor, balance = checkpoint
      unless cursor.is_a?(Integer) && cursor >= 0 && balance.is_a?(String) && balance.match?(/\A(?:0|-?[1-9][0-9]*)\z/)
        raise ArgumentError, "invalid ledger checkpoint"
      end

      pending, earliest = db.get_first_row("SELECT COUNT(*), MIN(seq) FROM events WHERE seq > ?", [cursor])
      if earliest == cursor + 1
        raise ArgumentError, "checkpoint is behind a stored consecutive scan"
      end
      state = if earliest
                "Waiting for scan #{cursor + 1}; scan #{earliest} is already stored."
              else
                "Stream is caught up."
              end
      "Applied cursor: #{cursor}\nAdjustment balance: #{balance}\nPending events: #{pending}\n#{state}"
    rescue Errno::ENOENT, SQLite3::CantOpenException
      raise if File.exist?(path)

      "Ledger is missing (#{path})."
    ensure
      db&.close
    end
  end
end
