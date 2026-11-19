require "fileutils"
require_relative "payments"
require_relative "storage"

module ShopifyLedger
  # Copies the live ledger with SQLite's online backup API while webhooks and
  # workers keep writing. The copy is one committed snapshot, checked, and only
  # then renamed into place, so a partial file never appears at the destination.
  class Backup
    class Refused < StandardError; end

    def initialize(config)
      @config = config
      @storage = Storage.new(config.database, busy_timeout: 5000)
    end

    def create(destination)
      destination = File.expand_path(destination)
      raise Refused, "destination already exists" if File.exist?(destination)
      raise Refused, "destination is the live database" if destination == File.expand_path(@config.database)

      partial = "#{destination}.partial-#{Process.pid}"
      pages = @storage.connect do |source|
        copy = SQLite3::Database.new(partial)
        begin
          backup = SQLite3::Backup.new(copy, "main", source, "main")
          # One step copies every page under a single read snapshot.
          backup.step(-1)
          count = backup.pagecount
          backup.finish
          count
        ensure
          copy.close
        end
      end
      report = verify(partial)
      File.rename(partial, destination)
      report.merge(backup: destination, pages: pages, bytes: File.size(destination))
    ensure
      FileUtils.rm_f(partial) if partial && File.exist?(partial)
    end

    private

    def verify(path)
      db = SQLite3::Database.new(path, readonly: true)
      integrity = db.get_first_value("PRAGMA integrity_check")
      raise Refused, "backup failed integrity check: #{integrity}" unless integrity == "ok"
      raise Refused, "backup schema does not match this version" unless Storage.catalog(db) == Storage.catalogs.last

      totals = @config.shops.to_h { |shop| [shop, Payments.summary(db, shop)] }
      { integrity: integrity, deliveries: db.get_first_value("SELECT COUNT(*) FROM inbox"),
        transactions: db.get_first_value("SELECT COUNT(*) FROM transactions"), totals: totals }
    ensure
      db&.close
    end
  end
end
