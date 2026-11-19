require "json"
require "net/http"
require "openssl"
require "timeout"
require "webrick"
require_relative "crash_harness"

module ShopifyFixture
  ROOT = File.expand_path("../..", __dir__).freeze
  ALPHA = "alpha.myshopify.com".freeze
  BETA = "beta.myshopify.com".freeze
  ORDER = "gid://shopify/Order/101".freeze
  OTHER_ORDER = "gid://shopify/Order/102".freeze
  SALE = "gid://shopify/OrderTransaction/201".freeze
  REFUND = "gid://shopify/OrderTransaction/202".freeze
  SECRET = "synthetic-shopify-test-secret".freeze
  PATH = "/admin/api/2026-10/graphql.json".freeze

  def self.transaction(id, kind, amount, currency = "CAD", status = "SUCCESS")
    { id: id, kind: kind, status: status, amountSet: { shopMoney: { amount: amount, currencyCode: currency } } }
  end

  class Admin
    def initialize
      @mutex = Mutex.new
      @requests = []
      @responses = {}
      @validate = []
      @server = WEBrick::HTTPServer.new(Port: 0, BindAddress: "127.0.0.1", AccessLog: [],
                                       Logger: WEBrick::Log.new(File::NULL))
      @server.mount_proc(PATH) { |req, res| respond(req, res) }
      @thread = Thread.new { @server.start }
    end

    def endpoint
      "http://127.0.0.1:#{@server.listeners.first.addr[1]}#{PATH}"
    end

    def order(transactions, shop: ALPHA, id: ORDER, count: transactions.length, precision: "EXACT")
      arrange(shop, "OrderPayments", id,
              { data: { order: { id: id, transactions: transactions,
                                 transactionsCount: { count: count, precision: precision } } } })
    end

    def page(ids, after: nil, next_cursor: nil, shop: ALPHA)
      arrange(shop, "ReconcileOrders", after,
              { data: { orders: { nodes: ids.map { |id| { id: id } },
                                  pageInfo: { hasNextPage: !next_cursor.nil?, endCursor: next_cursor } } } })
    end

    def arrange(shop, operation, argument, body, code: 200, &during_request)
      @mutex.synchronize { @responses[[shop, operation, argument]] = [code, body, during_request] }
    end

    def requests
      @mutex.synchronize { @requests.dup }
    end

    def close
      @server.shutdown
      @thread.join(5) or raise "fake Admin HTTP server failed to shut down"
      raise @validate.join("\n") unless @validate.empty?
    end

    private

    def respond(request, response)
      raise "Expected POST #{PATH}" unless request.request_method == "POST" && request.path == PATH
      shop = [ALPHA, BETA].find { |candidate| request["x-shopify-access-token"] == "fake-token-for-#{candidate}" }
      raise "Unrecognized fake shop token" unless shop

      query = JSON.parse(request.body)
      operation = query.fetch("operationName")
      variables = query.fetch("variables")
      selection = query.fetch("query").gsub(/\s+/, " ")
      argument = case operation
                 when "OrderPayments"
                   raise "Incomplete GraphQL order selection" unless %w[transactions transactionsCount precision shopMoney currencyCode].all? { |field| selection.include?(field) }

                   variables.fetch("id")
                 when "ReconcileOrders"
                   raise "Expected UPDATED_AT sort" unless selection.include?("UPDATED_AT")
                   filter = variables.fetch("filter")
                   raise "Expected bounded updated_at window: #{filter}" unless filter.include?("updated_at:>=") && filter.include?("updated_at:<=")

                   variables["after"]
                 else
                   raise "Unexpected GraphQL operation #{operation.inspect}"
                 end

      code, body, during_request = @mutex.synchronize do
        @requests << { "shop" => shop, "operation" => operation, "variables" => variables }
        @responses.fetch([shop, operation, argument])
      end
      during_request&.call(variables)
      response.status = code
      response["Content-Type"] = "application/json"
      response.body = body.is_a?(String) ? body : JSON.generate(body)
    rescue StandardError => error
      @mutex.synchronize { @validate << error.message }
      response.status = 500
      response.body = JSON.generate(errors: [{ message: error.message }])
    end
  end

  class Run
    attr_reader :admin, :database

    def initialize(directory, admin)
      @directory = directory
      @admin = admin
      @database = File.join(directory, "shopify.sqlite3")
      config_path = File.join(directory, "config.json")
      @config_path = config_path
      configure
      @environment = CrashHarness::CLEAN_ENV.merge("SHOPIFY_LEDGER_CONFIG" => config_path,
                                                    "SHOPIFY_LEDGER_ALLOW_HTTP_LOOPBACK" => "1",
                                                    "SHOPIFY_LEDGER_PORT" => "0")
    end

    def configure(**settings)
      shops = [ALPHA, BETA].each_with_object({}) do |shop, configs|
        configs[shop] = { endpoint: admin.endpoint, token: "fake-token-for-#{shop}" }
      end
      File.write(@config_path, JSON.generate(database: database, secret: SECRET, shops: shops, **settings))
    end

    def with_endpoint(seam: nil)
      relative = seam ? "test/support/shopify-webhook-with-hooks" : "bin/shopify-webhook"
      executable = File.join(ROOT, relative)
      Open3.popen3(@environment.merge("SHOPIFY_TEST_CRASH" => seam), [executable, executable],
                   chdir: @directory) do |input, output, errors, waiter|
        input.close
        line = Timeout.timeout(15) { output.gets }
        if !line || !line.match?(/\AREADY \d+\n\z/)
          diagnostic = errors.read if waiter.join(0.1)
          raise "Expected webhook readiness, got #{line.inspect} #{diagnostic}"
        end

        @webhook_port = Integer(line.split.last)
        yield waiter
      ensure
        @webhook_port = nil
        if waiter.alive?
          begin
            Process.kill("TERM", waiter.pid)
          rescue Errno::ESRCH
            # The subprocess can exit between the liveness check and signal.
          end
          unless waiter.join(5)
            Process.kill("KILL", waiter.pid)
            waiter.join
          end
        end
      end
    end

    def deliver(id, topic: "orders/updated", shop: ALPHA, payload: nil, signature: nil)
      payload ||= if topic == "refunds/create"
                    { order_id: 101, id: 501, admin_graphql_api_id: "gid://shopify/Refund/501" }
                  else
                    { id: 101, admin_graphql_api_id: ORDER }
                  end
      body = payload.is_a?(String) ? payload : JSON.generate(payload)
      signature ||= [OpenSSL::HMAC.digest("SHA256", SECRET, body)].pack("m0")
      request = Net::HTTP::Post.new("/webhooks")
      request.body = body
      request["Content-Type"] = "application/json"
      request["X-Shopify-Hmac-Sha256"] = signature
      request["X-Shopify-Shop-Domain"] = shop
      request["X-Shopify-Topic"] = topic
      request["X-Shopify-Webhook-Id"] = id if id
      http = Net::HTTP.new("127.0.0.1", @webhook_port, nil)
      http.open_timeout = 3
      http.read_timeout = 5
      http.max_retries = 0
      http.start { |connection| connection.request(request) }.code.to_i
    end

    def command(relative, *args, seam: nil)
      executable = File.join(ROOT, relative)
      Open3.capture3(@environment.merge("SHOPIFY_TEST_CRASH" => seam), [executable, executable],
                     *args, chdir: @directory)
    end

    def json(relative, *args, success: true)
      stdout, stderr, status = command(relative, *args)
      unless success == status.success? && status.exited?
        raise "#{relative} #{args.inspect}: expected success=#{success}, got #{status.inspect}, stdout=#{stdout.inspect}, stderr=#{stderr.inspect}"
      end

      JSON.parse(stdout)
    end

    def worker(success: true)
      json("bin/shopify-worker", "--once", success: success)
    end

    def reconcile(success: true)
      if success
        json("bin/reconcile", ALPHA)
      else
        stdout, stderr, status = command("bin/reconcile", ALPHA)
        raise "Expected reconciliation to fail, got #{stdout.inspect}, #{stderr.inspect}, #{status.inspect}" unless status.exited? && !status.success?

        { "exit_status" => status.exitstatus, "stderr" => stderr }
      end
    end

    def summary(shop = ALPHA)
      json("bin/shopify-summary", shop)
    end

    def read(sql, parameters = [])
      rows = nil
      SQLite3::Database.new(database) { |connection| rows = connection.execute(sql, parameters) }
      rows
    end

    def snapshot
      {
        "inbox" => read("SELECT shop, webhook_id, order_id, processed FROM inbox ORDER BY id"),
        "transactions" => read("SELECT shop, transaction_id, currency, kind, amount FROM transactions ORDER BY shop, transaction_id"),
        "checkpoints" => read("SELECT shop, synced_through FROM checkpoints ORDER BY shop")
      }
    end
  end

  def self.run
    Dir.mktmpdir("shopify-ledger-fixture-") do |directory|
      admin = Admin.new
      yield Run.new(directory, admin)
    ensure
      admin&.close
    end
  end
end
