require "json"
require "uri"

module ShopifyLedger
  class Config
    API_VERSION = "2026-10".freeze
    API_PATH = "/admin/api/#{API_VERSION}/graphql.json".freeze
    SHOP = /\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.myshopify\.com\z/

    DEFAULT_MAX_ATTEMPTS = 12

    DEFAULT_API_ATTEMPTS = 3

    DEFAULT_API_READ_TIMEOUT = 10

    attr_reader :database, :secret, :max_attempts, :api_attempts, :api_read_timeout, :path

    def self.load
      read(ENV.fetch("SHOPIFY_LEDGER_CONFIG"))
    rescue KeyError, JSON::ParserError => error
      raise ArgumentError, "invalid Shopify ledger configuration (#{error.class})"
    end

    def self.read(path)
      path = File.expand_path(path)
      new(JSON.parse(File.read(path)), File.dirname(path), path: path)
    rescue JSON::ParserError => error
      raise ArgumentError, "invalid Shopify ledger configuration (#{error.class})"
    end

    def initialize(data, directory, path: nil)
      raise ArgumentError, "configuration must be a JSON object" unless data.is_a?(Hash)

      @path = path&.freeze
      @database = File.expand_path(required_string(data, "database"), directory).freeze
      @secret = required_string(data, "secret").freeze
      @max_attempts = data.fetch("max_attempts", DEFAULT_MAX_ATTEMPTS)
      unless @max_attempts.is_a?(Integer) && @max_attempts.between?(1, 1000)
        raise ArgumentError, "max_attempts must be an integer from 1 to 1000"
      end
      @api_attempts = data.fetch("api_attempts", DEFAULT_API_ATTEMPTS)
      unless @api_attempts.is_a?(Integer) && @api_attempts.between?(1, 10)
        raise ArgumentError, "api_attempts must be an integer from 1 to 10"
      end
      @api_read_timeout = data.fetch("api_read_timeout", DEFAULT_API_READ_TIMEOUT)
      unless @api_read_timeout.is_a?(Numeric) && @api_read_timeout.between?(0.05, 60)
        raise ArgumentError, "api_read_timeout must be a number of seconds from 0.05 to 60"
      end
      named = data.fetch("databases", {})
      unless named.is_a?(Hash) && named.all? { |name, path| name.is_a?(String) && path.is_a?(String) && !path.empty? }
        raise ArgumentError, "databases must map names to paths"
      end
      @databases = named.transform_values { |path| File.expand_path(path, directory).freeze }.freeze
      shops = data["shops"]
      raise ArgumentError, "configure at least one shop" unless shops.is_a?(Hash) && !shops.empty?

      @shops = shops.each_with_object({}) do |(shop, settings), routes|
        unless SHOP.match?(shop) && settings.is_a?(Hash)
          raise ArgumentError, "invalid shop configuration"
        end

        token = required_string(settings, "token")
        endpoint = settings.fetch("endpoint", "https://#{shop}#{API_PATH}")
        validate_endpoint(endpoint, shop)
        route = settings["database"]
        raise ArgumentError, "shop #{shop} names an unknown database" unless route.nil? || @databases.key?(route)

        routes[shop] = { "endpoint" => endpoint.freeze, "token" => token.freeze,
                         "database" => route ? @databases[route] : @database }.freeze
      end.freeze
    end

    def shops
      @shops.keys
    end

    # The SQLite file that holds a shop's inbox and ledger. Unrouted shops use
    # the top-level database.
    def database_for(shop)
      @shops[shop]&.fetch("database") || @database
    end

    def database_named(name)
      return @database if name.nil?

      @databases.fetch(name) { raise ArgumentError, "unknown database #{name.inspect}" }
    end

    def all_databases
      [@database, *@databases.values].uniq
    end

    def shop?(shop)
      @shops.key?(shop)
    end

    def api(shop)
      @shops.fetch(shop) { raise ArgumentError, "shop is not configured" }
    end

    private

    def required_string(data, key)
      value = data[key]
      unless value.is_a?(String) && !value.strip.empty? && !value.match?(/[[:cntrl:]]/)
        raise ArgumentError, "invalid configuration field #{key}"
      end

      value
    end

    def validate_endpoint(endpoint, shop)
      uri = URI.parse(endpoint) if endpoint.is_a?(String)
      if uri && uri.path == API_PATH && !uri.userinfo && !uri.query && !uri.fragment
        return if uri.scheme == "https" && uri.host == shop && uri.port == 443
        return if ENV["SHOPIFY_LEDGER_ALLOW_HTTP_LOOPBACK"] == "1" &&
                  uri.scheme == "http" && uri.host == "127.0.0.1" && uri.port.between?(1, 65_535)
      end
      raise ArgumentError, "invalid Admin API endpoint for configured shop"
    rescue URI::InvalidURIError
      raise ArgumentError, "invalid Admin API endpoint for configured shop"
    end
  end
end
