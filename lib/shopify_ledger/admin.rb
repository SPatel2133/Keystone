require "json"
require "net/http"
require "openssl"
require "uri"
require "zlib"
require_relative "config"
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

    def initialize(config, shop)
      settings = config.api(shop)
      @endpoint = URI(settings.fetch("endpoint").to_s)
      @token = settings.fetch("token")
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
      http = Net::HTTP.new(@endpoint.hostname, @endpoint.port, nil)
      http.use_ssl = @endpoint.scheme == "https"
      http.open_timeout = 5
      http.read_timeout = 10
      http.write_timeout = 5

      post = Net::HTTP::Post.new(@endpoint.request_uri)
      post["Content-Type"] = "application/json"
      post["X-Shopify-Access-Token"] = @token
      post.body = JSON.generate(query: query, operationName: operation, variables: variables)
      response = http.request(post)

      raise Error, "Admin API returned HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      served_version = response["X-Shopify-API-Version"]
      if served_version && served_version != Config::API_VERSION
        raise Error, "Admin API did not serve the pinned version"
      end

      body = StrictJSON.parse(response.body.to_s)
      unless body.is_a?(Hash) && (!body.key?("errors") || body["errors"] == []) && body["data"].is_a?(Hash)
        raise Error, "Admin API returned GraphQL errors or missing data"
      end

      search = body.dig("extensions", "search") if body["extensions"].is_a?(Hash)
      if search.is_a?(Array) && search.any? { |entry| entry.is_a?(Hash) && entry["warnings"].is_a?(Array) && !entry["warnings"].empty? }
        raise Error, "Admin API reported search warnings"
      end

      body.fetch("data")
    rescue JSON::ParserError
      raise Error, "Admin API returned invalid JSON"
    rescue IOError, SocketError, SystemCallError, Net::ProtocolError, Net::HTTPBadResponse,
           Net::HTTPHeaderSyntaxError, Timeout::Error, OpenSSL::SSL::SSLError, Zlib::Error => error
      raise Error, "Admin API request failed (#{error.class})"
    end
  end
end
