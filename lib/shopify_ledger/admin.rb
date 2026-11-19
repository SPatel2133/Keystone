require "json"
require "net/http"
require "openssl"
require "uri"
require "zlib"
require_relative "config"
require_relative "log"
require_relative "strict_json"

module ShopifyLedger
  class Admin
    ORDER_ID = %r{\Agid://shopify/Order/[1-9][0-9]*\z}.freeze
    TRANSACTION_ID = %r{\Agid://shopify/OrderTransaction/[1-9][0-9]*\z}.freeze

    class Error < StandardError; end

    ORDER_PAYMENTS = <<~GRAPHQL.freeze
      query OrderPayments($id: ID!) {
        order(id: $id) {
          id
          transactionsCount { count precision }
          transactions {
            id
            kind
            status
            amountSet { shopMoney { amount currencyCode } }
          }
        }
      }
    GRAPHQL

    RECONCILE_ORDERS = <<~GRAPHQL.freeze
      query ReconcileOrders($filter: String!, $after: String) {
        orders(first: 50, query: $filter, sortKey: UPDATED_AT, after: $after) {
          nodes { id }
          pageInfo { hasNextPage endCursor }
        }
      }
    GRAPHQL

    # Raised for failures that may succeed on an immediate retry: throttling,
    # gateway/server errors and connection failures. All queries are read-only,
    # so repeating one cannot change Shopify state.
    class Transient < Error
      attr_reader :retry_after

      def initialize(message, retry_after = nil)
        super(message)
        @retry_after = retry_after
      end
    end

    RETRY_STATUSES = [429, 500, 502, 503, 504].freeze
    BASE_DELAY = 0.25
    MAX_DELAY = 2.0
    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 10
    WRITE_TIMEOUT = 5

    def self.delay(attempt, retry_after = nil)
      requested = retry_after || BASE_DELAY * (2**(attempt - 1))
      requested.clamp(0, MAX_DELAY)
    end

    def initialize(config, shop, sleeper: ->(seconds) { sleep(seconds) })
      settings = config.api(shop)
      @shop = shop
      @endpoint = URI(settings.fetch("endpoint").to_s)
      @token = settings.fetch("token")
      @attempts = config.api_attempts
      @sleeper = sleeper
    end

    def order_transactions(order_id)
      data = request("OrderPayments", ORDER_PAYMENTS, id: order_id)
      order = data["order"]
      unless order.is_a?(Hash) && order["id"] == order_id
        raise Error, "Admin API returned a missing or mismatched order"
      end

      transactions = order["transactions"]
      count = order["transactionsCount"]
      unless transactions.is_a?(Array) && count.is_a?(Hash) &&
             count["count"].is_a?(Integer) && count["count"] == transactions.length &&
             count["precision"] == "EXACT"
        raise Error, "Admin API did not return a complete transaction list"
      end

      ids = transactions.map { |row| row["id"] if row.is_a?(Hash) }
      unless ids.all? { |id| id.is_a?(String) && id.match?(TRANSACTION_ID) } &&
             ids.uniq.length == ids.length
        raise Error, "Admin API returned missing, invalid or repeated transaction IDs"
      end

      transactions
    end

    def orders_page(filter, after)
      data = request("ReconcileOrders", RECONCILE_ORDERS, filter: filter, after: after)
      orders = data["orders"]
      nodes = orders["nodes"] if orders.is_a?(Hash)
      page_info = orders["pageInfo"] if orders.is_a?(Hash)
      unless nodes.is_a?(Array) && page_info.is_a?(Hash) &&
             [true, false].include?(page_info["hasNextPage"]) &&
             page_info.key?("endCursor")
        raise Error, "Admin API returned malformed order pagination"
      end

      ids = nodes.map { |node| node["id"] if node.is_a?(Hash) }
      unless ids.all? { |id| id.is_a?(String) && id.match?(ORDER_ID) } && ids.uniq.length == ids.length
        raise Error, "Admin API returned missing, invalid or repeated order IDs"
      end

      more = page_info["hasNextPage"]
      cursor = page_info["endCursor"]
      if more && (ids.empty? || !cursor.is_a?(String) || cursor.empty?)
        raise Error, "Admin API omitted the next page cursor or returned an empty intermediate page"
      end

      [ids, more ? cursor : nil]
    end

    private

    def request(operation, query, variables)
      attempt = 0
      begin
        attempt += 1
        request_once(operation, query, variables)
      rescue Transient => error
        raise if attempt >= @attempts

        delay = self.class.delay(attempt, error.retry_after)
        Log.event("admin_api_retry", shop: @shop, operation: operation, attempt: attempt,
                                     delay_seconds: delay, error: error.message)
        @sleeper.call(delay)
        retry
      end
    end

    def request_once(operation, query, variables)
      http = Net::HTTP.new(@endpoint.hostname, @endpoint.port, nil)
      http.use_ssl = @endpoint.scheme == "https"
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT
      http.write_timeout = WRITE_TIMEOUT

      post = Net::HTTP::Post.new(@endpoint.request_uri)
      post["Content-Type"] = "application/json"
      post["X-Shopify-Access-Token"] = @token
      post.body = JSON.generate(query: query, operationName: operation, variables: variables)
      response = http.request(post)

      unless response.is_a?(Net::HTTPSuccess)
        message = "Admin API returned HTTP #{response.code}"
        raise Error, message unless RETRY_STATUSES.include?(response.code.to_i)

        retry_after = Float(response["Retry-After"], exception: false)
        raise Transient.new(message, retry_after&.positive? ? retry_after : nil)
      end

      served_version = response["X-Shopify-API-Version"]
      if served_version && served_version != Config::API_VERSION
        raise Error, "Admin API did not serve the pinned version"
      end

      body = StrictJSON.parse(response.body.to_s)
      if body.is_a?(Hash) && body["errors"].is_a?(Array) &&
         body["errors"].any? { |e| e.is_a?(Hash) && e.dig("extensions", "code") == "THROTTLED" }
        raise Transient.new("Admin API throttled the query", bucket_wait(body))
      end
      unless body.is_a?(Hash) && (!body.key?("errors") || body["errors"] == []) && body["data"].is_a?(Hash)
        raise Error, "Admin API returned GraphQL errors or missing data"
      end

      search = body.dig("extensions", "search") if body["extensions"].is_a?(Hash)
      if search.is_a?(Array) && search.any? { |entry| entry.is_a?(Hash) && entry["warnings"].is_a?(Array) && !entry["warnings"].empty? }
        raise Error, "Admin API reported search warnings"
      end

      pace(operation, body)
      body.fetch("data")
    rescue JSON::ParserError
      raise Error, "Admin API returned invalid JSON"
    rescue IOError, SocketError, SystemCallError, Net::ProtocolError, Net::HTTPBadResponse,
           Net::HTTPHeaderSyntaxError, Timeout::Error, OpenSSL::SSL::SSLError, Zlib::Error => error
      raise Transient, "Admin API request failed (#{error.class})"
    end

    # Shopify meters GraphQL by query cost from a leaky bucket and reports it in
    # extensions.cost. Waiting for the bucket to refill before the next call is
    # cheaper than being throttled and retrying.
    def pace(operation, body)
      wait = bucket_wait(body)
      return unless wait

      Log.event("admin_api_pacing", shop: @shop, operation: operation, wait_seconds: wait)
      @sleeper.call(wait)
    end

    def bucket_wait(body)
      cost = body.dig("extensions", "cost") if body["extensions"].is_a?(Hash)
      return unless cost.is_a?(Hash) && cost["throttleStatus"].is_a?(Hash)

      requested = cost["requestedQueryCost"]
      available, rate = cost["throttleStatus"].values_at("currentlyAvailable", "restoreRate")
      return unless [requested, available, rate].all? { |value| value.is_a?(Numeric) && value >= 0 } && rate.positive?

      deficit = requested - available
      deficit.positive? ? [(deficit / rate.to_f).round(3), MAX_DELAY].min : nil
    end
  end
end
