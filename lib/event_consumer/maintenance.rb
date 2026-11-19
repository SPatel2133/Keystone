require_relative "ledger"

module EventConsumer
  module Maintenance
    def self.run(path)
      # Opening READWRITE without CREATE keeps a mistyped path absent.
      SQLite3::Database.new(path, readwrite: true) do |db|
        db.busy_timeout(Ledger::BUSY_TIMEOUT_MS)
        # VACUUM must execute outside a transaction. Hold exclusive locking
        # mode across the schema check, transaction end, VACUUM and measurements.
        db.execute("PRAGMA locking_mode = EXCLUSIVE")
        db.execute("BEGIN EXCLUSIVE")
        schema = db.execute("SELECT type, name, sql FROM sqlite_schema WHERE name NOT GLOB 'sqlite_*' ORDER BY name")
        expected = Ledger::SCHEMA.map { |name, sql| ["table", name, sql] }
        raise ArgumentError, "incompatible ledger schema" unless schema == expected

        before = size(db, path)
        db.execute("COMMIT")
        db.execute("VACUUM")
        return { before: before, after: size(db, path) }
      end
    end

    def self.size(db, path)
      {
        main_file_bytes: File.size(path),
        pages: db.get_first_value("PRAGMA page_count"),
        free_pages: db.get_first_value("PRAGMA freelist_count")
      }
    end
    private_class_method :size
  end
end
