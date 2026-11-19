require_relative "../event_consumer/bundle"
require_relative "config"
require_relative "storage"

module ShopifyLedger
  module CLI
    def self.run(command, arguments, **hooks)
      STDOUT.sync = true
      if command == :worker
        raise ArgumentError, "usage: bin/shopify-worker --once" unless arguments == ["--once"]

        require_relative "worker"
        status = Worker.new(Config.load).run_once(**hooks)
        puts JSON.generate(status: status)
        return %w[retry parked].include?(status) ? 1 : 0
      end

      return deliveries(arguments) if command == :deliveries

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
