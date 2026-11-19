require_relative "payments"
require_relative "storage"

module ShopifyLedger
  # Validates the schema and runs VACUUM under SQLite exclusive locking mode,
  # so no webhook or worker can write between the check and the rebuild.
  module Maintenance
    def self.run(config, database: config.database)
      path = database
      shops = config.shops.select { |shop| config.database_for(shop) == path }
      raise ArgumentError, "ledger database does not exist" unless File.exist?(path)

      SQLite3::Database.new(path, readwrite: true) do |db|
        db.busy_timeout(250)
        db.execute("PRAGMA locking_mode = EXCLUSIVE")
        db.execute("BEGIN EXCLUSIVE")
        raise ArgumentError, "incompatible Shopify ledger schema" unless Storage.catalog(db) == Storage.catalogs.last

        totals = shops.to_h { |shop| [shop, Payments.summary(db, shop)] }
        before = size(db, path)
        db.execute("COMMIT")
        db.execute("VACUUM")
        after_totals = shops.to_h { |shop| [shop, Payments.summary(db, shop)] }
        raise "totals changed during maintenance" unless after_totals == totals

        return { before: before, after: size(db, path), totals: totals }
      end
    end

    def self.size(db, path)
      { main_file_bytes: File.size(path), pages: db.get_first_value("PRAGMA page_count"),
        free_pages: db.get_first_value("PRAGMA freelist_count") }
    end
    private_class_method :size
  end
end
