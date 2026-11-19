require "json"
require "socket"

module ShopifyLedger
  module Postgres
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
      in ["reconcile", String => shop]
        require_relative "../reconciliation"
        checkpoint = Reconciliation.new(worker_config = Config.load, store: Store.new(db)).run(shop)
        worker_config.api(shop)
        puts JSON.generate(shop: shop, synced_through: checkpoint)
        0
      in ["status", *shops]
        require_relative "../status"
        config = Config.load
        shops = config.shops if shops.empty?
        shops.each { |shop| config.api(shop) }
        report = Status.new(config, store: Store.new(db)).report(shops)
        puts JSON.generate(generated_at: Time.now.utc.iso8601, shops: report)
        report.all? { |shop| shop[:health] == "ok" } ? 0 : 2
      in ["audit", String => shop, *rest] if rest.empty? || (rest.size == 2 && rest.first == "--order")
        require_relative "../audit"
        Config.load.api(shop)
        puts JSON.generate(Audit.new(Config.load, store: Store.new(db)).report(shop, order_id: rest.last))
        0
      in ["deliveries", "list", String => shop, String => state]
        require_relative "../deliveries"
        puts JSON.generate(shop: shop, deliveries: Deliveries.new(Config.load, store: Store.new(db)).list(shop, state))
        0
      in ["deliveries", "retry", String => shop, String => webhook_id]
        require_relative "../deliveries"
        puts JSON.generate(Deliveries.new(Config.load, store: Store.new(db)).retry(shop, webhook_id))
        0
      in ["summary", String => shop]
        puts JSON.generate(shop: shop, totals: Payments.summary(db, shop))
        0
      else
        raise ArgumentError, "usage: bin/shopify-pg-worker --once | --drain | reconcile SHOP | status [SHOP...] | summary SHOP | " \
                            "audit SHOP [--order ORDER_GID] | deliveries list SHOP STATE | deliveries retry SHOP WEBHOOK_ID"
      end
    ensure
      db&.close
    end
  end
end
