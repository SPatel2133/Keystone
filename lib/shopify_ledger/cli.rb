require_relative "../event_consumer/bundle"
require_relative "config"
require_relative "storage"

module ShopifyLedger
  module CLI
    def self.run(command, arguments, **hooks)
      STDOUT.sync = true
      return worker(arguments, hooks) if command == :worker

      return deliveries(arguments) if command == :deliveries
      return status(arguments) if command == :status
      return audit(arguments) if command == :audit

      script = command == :summary ? "shopify-summary" : "reconcile"
      raise ArgumentError, "usage: bin/#{script} SHOP" unless arguments.size == 1

      shop = arguments.first
      config = Config.load
      config.api(shop)
      if command == :summary
        require_relative "payments"
        totals = Storage.new(config.database).connect { |db| Payments.summary(db, shop) }
        puts JSON.generate(shop: shop, totals: totals)
      else
        require_relative "reconciliation"
        checkpoint = Reconciliation.new(config).run(shop)
        puts JSON.generate(shop: shop, synced_through: checkpoint)
      end
      0
    rescue StandardError => error
      warn "shopify ledger: #{error.class}: #{error.message}"
      1
    end

    # --once prints one outcome; --drain prints counts and stops when idle.
    # Both exit 1 when any delivery was deferred or parked.
    def self.worker(arguments, hooks)
      usage = "usage: bin/shopify-worker --once | --drain [--limit N]"
      limit = nil
      case arguments
      in ["--once"]
      in ["--drain"]
      in ["--drain", "--limit", String => count]
        limit = Integer(count, 10, exception: false)
        raise ArgumentError, usage unless limit&.between?(1, 1_000_000)
      else
        raise ArgumentError, usage
      end
      raise ArgumentError, usage if hooks.any? && arguments != ["--once"]

      require_relative "worker"
      worker = Worker.new(Config.load)
      if arguments == ["--once"]
        status = worker.run_once(**hooks)
        puts JSON.generate(status: status)
        return %w[retry parked].include?(status) ? 1 : 0
      end

      counts = worker.drain(limit: limit)
      puts JSON.generate(counts)
      counts.values_at("retry", "parked").sum.zero? && counts["status"] != "storage_error" ? 0 : 1
    end

    # Exit 0 when every shop is healthy, 2 when any shop needs attention.
    def self.status(arguments)
      raise ArgumentError, "usage: bin/shopify-status [SHOP]" if arguments.size > 1

      require_relative "status"
      config = Config.load
      shops = arguments.empty? ? config.shops : arguments.each { |shop| config.api(shop) }
      report = Status.new(config).report(shops)
      puts JSON.generate(generated_at: Time.now.utc.iso8601, shops: report)
      report.all? { |shop| shop[:health] == "ok" } ? 0 : 2
    end

    AUDIT_USAGE = "usage: bin/shopify-audit SHOP [--order ORDER_GID | --limit N]"

    def self.audit(arguments)
      require_relative "audit"
      shop, option, value, *extra = arguments
      raise ArgumentError, AUDIT_USAGE unless shop && extra.empty? && (option.nil? || value)

      config = Config.load
      config.api(shop)
      options = case option
                when nil then {}
                when "--order" then { order_id: value }
                when "--limit"
                  limit = Integer(value, exception: false)
                  raise ArgumentError, AUDIT_USAGE unless limit&.between?(1, 100_000)

                  { limit: limit }
                else raise ArgumentError, AUDIT_USAGE
                end
      puts JSON.generate(Audit.new(config).report(shop, **options))
      0
    end

    DELIVERIES_USAGE = "usage: bin/shopify-deliveries list SHOP [--state STATE] | retry SHOP WEBHOOK_ID"

    def self.deliveries(arguments)
      require_relative "deliveries"
      action, shop, *rest = arguments
      config = Config.load
      raise ArgumentError, DELIVERIES_USAGE unless shop

      config.api(shop)
      deliveries = Deliveries.new(config)
      case [action, rest.size]
      in ["list", 0] | ["list", 2]
        raise ArgumentError, DELIVERIES_USAGE unless rest.empty? || rest.first == "--state"

        state = rest.fetch(1, "pending")
        puts JSON.generate(shop: shop, state: state, deliveries: deliveries.list(shop, state))
      in ["retry", 1]
        puts JSON.generate(shop: shop, delivery: deliveries.retry(shop, rest.first))
      else
        raise ArgumentError, DELIVERIES_USAGE
      end
      0
    rescue Deliveries::Refused => error
      puts JSON.generate(shop: shop, webhook_id: rest&.first, refused: error.message)
      1
    end
  end
end
