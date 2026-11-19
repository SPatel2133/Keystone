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
        return status == "retry" ? 1 : 0
      end

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
  end
end
