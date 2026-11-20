require "json"
require_relative "config"
require_relative "payments"
require_relative "storage"

module ShopifyLedger
  # Moves one shop's inbox, ledger and reconciliation progress to another
  # routed SQLite database:
  #   1. copy every row for the shop in one transaction, and verify the copy
  #      row for row before committing;
  #   2. switch the route by atomically replacing the config file;
  #   3. delete the shop's rows from every other database, but only where they
  #      equal the destination copy.
  # A crash at any point leaves exactly one routed, complete copy, and rerunning
  # the command finishes the move. Stop ingest and workers for the shop first:
  # running processes keep the route they loaded.
  module MoveShop
    class Refused < StandardError; end

    TABLES = %w[inbox transactions payment_events checkpoints reconciliation_runs reconciliation_starts].freeze
    IDENTITY = "id".freeze

    def self.run(config_path, shop, to, after_copy: nil, after_switch: nil)
      config_path = File.expand_path(config_path)
      mode = File.stat(config_path).mode & 0o7777
      lock_path = "#{config_path}.lock"
      File.open(lock_path, File::RDWR | File::CREAT, mode) do |lock|
        File.chmod(mode, lock_path)
        lock.flock(File::LOCK_EX)
        config = Config.read(config_path)
        raise Refused, "shop is not configured" unless config.shop?(shop)

        destination = config.database_named(to)
        source = config.database_for(shop)
        copied = nil
        if source != destination
          Storage.new(destination).connect { nil }
          copied = copy(source, destination, shop)
          after_copy&.call
          switch(config_path, shop, to)
          after_switch&.call
        end
        removed = (config.all_databases - [destination]).to_h { |path| [path, clean(path, destination, shop)] }
        totals = Storage.new(destination).connect { |db| Payments.summary(db, shop) }
        { shop: shop, to: to, database: destination, copied: copied, removed: removed.reject { |_, count| count.zero? },
          totals: totals }.compact
      end
    end

    def self.cli(arguments, **hooks)
      unless arguments.size == 3 && arguments[1] == "--to"
        warn "usage: bin/shopify-move-shop SHOP --to DATABASE_NAME"
        return 64
      end
      config_path = File.expand_path(ENV.fetch("SHOPIFY_LEDGER_CONFIG"))
      puts JSON.generate(run(config_path, arguments[0], arguments[2], **hooks))
      0
    rescue Refused, ArgumentError, KeyError, SQLite3::Exception => error
      warn "shopify ledger: #{error.message}"
      1
    end

    def self.columns(db, schema, table)
      db.execute("PRAGMA #{schema}.table_info(#{table})").map { |row| row[1] } - [IDENTITY]
    end

    def self.rows(db, schema, table, shop, list)
      db.execute("SELECT #{list} FROM #{schema}.#{table} WHERE shop = ? ORDER BY #{list}", [shop])
    end

    def self.attached(path, other)
      Storage.new(path).connect do |db|
        db.execute("ATTACH DATABASE ? AS other", [other])
        return yield db
      end
    end

    def self.copy(source, destination, shop)
      attached(source, destination) do |db|
        Storage.transaction(db) do
          TABLES.to_h do |table|
            list = columns(db, "main", table).join(", ")
            ordered = columns(db, "main", table).size < db.execute("PRAGMA main.table_info(#{table})").size ? " ORDER BY id" : ""
            if (key = KEYS[table])
              missing = db.get_first_value(<<~SQL, [shop, shop])
                SELECT COUNT(*) FROM other.#{table}
                WHERE shop = ? AND #{key} NOT IN (SELECT #{key} FROM main.#{table} WHERE shop = ?)
              SQL
              raise Refused, "#{destination} has #{missing} #{table} rows for #{shop} that the source lacks; reconcile them by hand" if missing.positive?
            end

            # Rows left by an earlier attempt that crashed before switching.
            db.execute("DELETE FROM other.#{table} WHERE shop = ?", [shop])
            db.execute("INSERT INTO other.#{table} (#{list}) SELECT #{list} FROM main.#{table} WHERE shop = ?#{ordered}", [shop])
            copy = rows(db, "other", table, shop, list)
            raise Refused, "#{table} copy does not match the source" unless copy == rows(db, "main", table, shop, list)

            [table, copy.size]
          end
        end
      end
    end

    def self.switch(config_path, shop, to)
      data = JSON.parse(File.read(config_path))
      stat = File.stat(config_path)
      mode = stat.mode & 0o7777
      data.fetch("shops").fetch(shop)["database"] = to
      temporary = "#{config_path}.move-#{Process.pid}"
      File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.write(JSON.pretty_generate(data))
        file.flush
        file.fsync
      end
      begin
        File.chown(stat.uid, stat.gid, temporary)
      rescue Errno::EPERM
        nil
      end
      File.chmod(mode, temporary)
      File.rename(temporary, config_path)
    end

    # Deletes the shop's rows from a database it no longer routes to. A stale
    # copy (left by a crash, then outdated as the shop kept working) loses
    # nothing when deleted. Deliveries or payments that the routed copy lacks
    # were written after the copy by a process on the old route; those need an operator.
    KEYS = { "inbox" => "webhook_id", "transactions" => "transaction_id", "payment_events" => "transaction_id" }.freeze

    def self.clean(path, destination, shop)
      return 0 unless File.exist?(path)

      attached(path, destination) do |db|
        Storage.transaction(db) do
          KEYS.each do |table, key|
            missing = db.get_first_value(<<~SQL, [shop, shop])
              SELECT COUNT(*) FROM main.#{table}
              WHERE shop = ? AND #{key} NOT IN (SELECT #{key} FROM other.#{table} WHERE shop = ?)
            SQL
            next if missing.zero?

            raise Refused, "#{path} has #{missing} #{table} rows for #{shop} that the routed copy lacks; " \
                           "stop ingest for the shop, then reconcile them by hand"
          end
          TABLES.sum do |table|
            db.execute("DELETE FROM main.#{table} WHERE shop = ?", [shop])
            db.changes
          end
        end
      end
    end
  end
end
