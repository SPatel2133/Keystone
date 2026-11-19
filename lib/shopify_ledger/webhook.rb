require "base64"
require "json"
require "openssl"
require "webrick"
require_relative "config"
require_relative "inbox"
require_relative "strict_json"

module ShopifyLedger
  class Webhook
    TOPICS = %w[orders/updated refunds/create].freeze
    ORDER_GID = %r{\Agid://shopify/Order/[1-9][0-9]*\z}
    DELIVERY_ID = /\A[!-~]{1,255}\z/

    def initialize(config, after_commit: nil)
      @config = config
      @inboxes = Hash.new { |cache, path| cache[path] = Inbox.new(Storage.new(path)) }
      @after_commit = after_commit
    end

    def self.run(after_commit: nil)
      STDOUT.sync = true
      port = Integer(ENV.fetch("SHOPIFY_LEDGER_PORT", "9292"), 10)
      raise ArgumentError, "SHOPIFY_LEDGER_PORT must be between 0 and 65535" unless port.between?(0, 65_535)

      handler = new(Config.load, after_commit: after_commit)
      server = WEBrick::HTTPServer.new(
        BindAddress: "127.0.0.1",
        Port: port,
        AccessLog: [],
        Logger: WEBrick::Log.new($stderr, WEBrick::Log::ERROR),
        StartCallback: -> { puts "READY #{server.listeners.fetch(0).addr.fetch(1)}" }
      )
      server.mount_proc("/webhooks") { |request, response| handler.call(request, response) }
      %w[INT TERM].each { |signal| Signal.trap(signal) { server.shutdown } }
      server.start
    end

    def call(request, response)
      return respond(response, 404, "not_found") unless request.path == "/webhooks"
      unless request.request_method == "POST"
        response["Allow"] = "POST"
        return respond(response, 405, "method_not_allowed")
      end

      body = request.body || ""
      signature = header(request, "x-shopify-hmac-sha256")
      return respond(response, 401, "invalid_signature") unless signed?(body, signature)

      shop = header(request, "x-shopify-shop-domain")
      webhook_id = header(request, "x-shopify-webhook-id")
      topic = header(request, "x-shopify-topic")
      unless shop && webhook_id && DELIVERY_ID.match?(webhook_id) && TOPICS.include?(topic)
        return respond(response, 400, "invalid_delivery_metadata")
      end
      return respond(response, 403, "unconfigured_shop") unless @config.shop?(shop)

      payload = parse(body)
      order_id = order_gid(topic, payload) if payload.is_a?(Hash)
      return respond(response, 400, "invalid_payload") unless order_id

      @inboxes[@config.database_for(shop)].receive(shop: shop, webhook_id: webhook_id, topic: topic, order_id: order_id, after_commit: @after_commit)
      respond(response, 200)
    rescue Inbox::IdentityConflict
      respond(response, 409, "delivery_id_conflict")
    rescue SQLite3::BusyException, SQLite3::LockedException
      response["Retry-After"] = "1"
      respond(response, 503, "storage_busy")
    end

    private

    def header(request, name)
      values = request.header.fetch(name, [])
      return unless values.length == 1

      value = values.first
      # WEBrick returns binary strings, which sqlite3 binds as BLOBs.
      value.encode(Encoding::UTF_8) if !value.empty? && value.ascii_only?
    end

    def signed?(body, signature)
      return false unless signature

      supplied = Base64.strict_decode64(signature)
      expected = OpenSSL::HMAC.digest("SHA256", @config.secret, body)
      return false unless supplied.bytesize == expected.bytesize

      difference = 0
      expected.each_byte.with_index { |byte, index| difference |= byte ^ supplied.getbyte(index) }
      difference.zero?
    rescue ArgumentError
      false
    end

    def parse(body)
      StrictJSON.parse(body)
    rescue JSON::ParserError
      nil
    end

    def order_gid(topic, payload)
      return numeric_order_gid(payload["order_id"]) if topic == "refunds/create"

      numeric_gid = numeric_order_gid(payload["id"])
      return numeric_gid unless payload.key?("admin_graphql_api_id")

      gid = payload["admin_graphql_api_id"]
      return unless gid.is_a?(String) && ORDER_GID.match?(gid)
      return if payload.key?("id") && numeric_gid != gid

      gid
    end

    def numeric_order_gid(value)
      "gid://shopify/Order/#{value}" if value.is_a?(Integer) && value.positive?
    end

    def respond(response, status, error = nil)
      response.status = status
      response["Content-Type"] = "application/json"
      response.body = JSON.generate(error ? { error: error } : { status: "ok" })
    end
  end
end
