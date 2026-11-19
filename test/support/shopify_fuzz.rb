require "bigdecimal"
require "fileutils"
require "json"
require "set"
require_relative "shopify_fixture"
%w[config storage inbox payments worker reconciliation deliveries backup maintenance move_shop].each do |name|
  require_relative "../../lib/shopify_ledger/#{name}"
end

# Randomized crash testing of the Shopify ledger against a reference model.
# A seed expands into a list of abstract operations (deliveries, workers that
# crash at commit seams, Admin API faults, order mutations, reconciliation with
# failing pages, operator retries, backups, maintenance). The fake Admin API is
# the ground truth; invariants are checked after every step, and a final settle
# phase must make the ledger equal the ground truth exactly.
module ShopifyFuzz
  include ShopifyFixture

  class Failure < StandardError; end
  class Crash < StandardError; end

  SHOPS = [ALPHA, BETA].freeze
  CURRENCIES = %w[CAD USD].freeze
  PAGE_SIZE = 3
  WEIGHTS = {
    "deliver" => 18, "duplicate" => 6, "worker" => 16, "crash_before_commit" => 3, "crash_after_commit" => 3,
    "orphan_claim" => 3, "admin_fault" => 6, "mutate" => 16, "advance_time" => 5, "operator_retry" => 3,
    "reconcile" => 5, "reconcile_failing_page" => 3, "backup" => 1, "maintain" => 1, "complete_pending" => 4,
    "admin_stale_read" => 3, "move_shop" => 3
  }.freeze
  PROCESS_WEIGHTS = { "drain_processes" => 2, "kill_mid_fetch" => 2 }.freeze

  def self.generate(seed, steps, processes: false)
    random = Random.new(seed)
    weights = processes ? WEIGHTS.merge(PROCESS_WEIGHTS) : WEIGHTS
    bag = weights.flat_map { |op, weight| [op] * weight }
    [{ "op" => "setup", "a" => 1 + random.rand(20) }] +
      Array.new(steps) { { "op" => bag[random.rand(bag.size)], "a" => random.rand(2**30), "b" => random.rand(2**30), "c" => random.rand(2**30) } }
  end

  # Runs one operation list; returns nil on success or a failure hash.
  def self.execute(ops, backend: :sqlite)
    (backend == :postgres ? PostgresExecution : Execution).new(ops).call
    nil
  rescue Failure => error
    { "message" => error.message }
  end

  # Drops operations while the failure still reproduces: halving chunks first
  # for speed, then one operation at a time until nothing more can go.
  def self.shrink(ops, backend: :sqlite)
    current = ops
    chunk = [(current.size - 1) / 2, 1].max
    loop do
      index = 1
      changed = false
      while index < current.size
        candidate = current[0...index] + (current[(index + chunk)..] || [])
        if execute(candidate, backend: backend)
          current = candidate
          changed = true
        else
          index += chunk
        end
      end
      if chunk > 1
        chunk /= 2
      elsif !changed
        return current
      end
    end
  end

  def self.campaign(seed:, runs:, steps:, processes: false, directory: nil, shrink: true, backend: :sqlite)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    counts = Hash.new(0)
    failures = []
    runs.times do |index|
      run_seed = seed + index
      ops = generate(run_seed, steps, processes: processes)
      ops.drop(1).each { |op| counts[op["op"]] += 1 }
      failure = execute(ops, backend: backend)
      next unless failure

      minimal = shrink ? shrink(ops, backend: backend) : ops
      record = { "seed" => run_seed, "steps" => steps, "processes" => processes, "backend" => backend.to_s,
                 "failure" => failure, "minimized_failure" => execute(minimal, backend: backend), "ops" => minimal }
      if directory
        FileUtils.mkdir_p(directory)
        record["file"] = File.join(directory, "fuzz-failure-#{run_seed}.json")
        File.write(record["file"], JSON.pretty_generate(record))
      end
      failures << record
    end
    { "seed" => seed, "runs" => runs, "steps" => steps, "processes" => processes, "backend" => backend.to_s,
      "operations" => counts.sort.to_h,
      "failures" => failures, "seconds" => (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(2) }
  end

  class Execution
    include ShopifyFixture

    def initialize(ops)
      @ops = ops
    end

    def call
      quiet do
        ShopifyFixture.run do |fixture|
          @fixture = fixture
          setup(@ops.first.fetch("a"))
          @ops.drop(1).each_with_index do |op, index|
            @step = "step #{index + 1} #{op["op"]}"
            send("op_#{op["op"]}", op["a"], op["b"], op["c"])
            @config.all_databases.each { |path| check_invariants(path) }
          end
          @step = "settle"
          settle
        end
      end
    end

    private

    def fail!(message) = raise(Failure, "#{@step}: #{message}")

    def quiet
      saved = $stderr
      $stderr = File.open(File::NULL, "w")
      saved_env = ENV.to_h.slice("SHOPIFY_LEDGER_CONFIG", "SHOPIFY_LEDGER_ALLOW_HTTP_LOOPBACK")
      yield
    ensure
      $stderr.close unless $stderr.equal?(saved)
      $stderr = saved
      %w[SHOPIFY_LEDGER_CONFIG SHOPIFY_LEDGER_ALLOW_HTTP_LOOPBACK].each { |key| ENV[key] = saved_env&.fetch(key, nil) }
    end

    def setup(orders)
      # Shops start in "main" and move between it and "eu".
      @fixture.configure(max_attempts: 3, databases: { "main" => File.basename(@fixture.database), "eu" => "eu.sqlite3" })
      @config_path = File.join(File.dirname(@fixture.database), "config.json")
      ENV["SHOPIFY_LEDGER_CONFIG"] = @config_path
      ENV["SHOPIFY_LEDGER_ALLOW_HTTP_LOOPBACK"] = "1"
      @config = ShopifyLedger::Config.load
      @storages = Hash.new { |cache, path| cache[path] = ShopifyLedger::Storage.new(path, busy_timeout: 5000) }
      @clock = Time.now
      @orders = SHOPS.product((1..orders).to_a).to_h do |shop, number|
        [[shop, number], { currency: CURRENCIES[(number + SHOPS.index(shop)) % 2], transactions: [], history: [] }]
      end
      @truth = {}
      @counters = Hash.new(0)
      @webhooks = []
      @checkpoints = {}
      @backups = 0
      @dead_pid = Process.spawn("true").tap { |pid| Process.wait(pid) }
      @orders.each_key { |key| arrange_truth(*key) }
      SHOPS.each { |shop| arrange_pages(shop) }
      @config.all_databases.each { |path| @storages[path].connect { |_db| nil } }
    end

    def gid(number) = "gid://shopify/Order/#{number}"
    def pick(list, value) = list.empty? ? nil : list[value % list.size]
    def order_key(a, b) = [SHOPS[a % SHOPS.size], 1 + (b % (@orders.size / SHOPS.size))]

    def order_body(shop, number)
      transactions = @orders.fetch([shop, number])[:transactions]
      { data: { order: { id: gid(number), transactions: transactions,
                         transactionsCount: { count: transactions.size, precision: "EXACT" } } } }
    end

    def arrange_truth(shop, number)
      order = @orders.fetch([shop, number])
      order[:history] << order[:transactions].dup unless order[:history].last == order[:transactions]
      @fixture.admin.arrange(shop, "OrderPayments", gid(number), order_body(shop, number))
    end

    def pages(shop)
      numbers = @orders.keys.select { |key| key.first == shop }.map(&:last)
      numbers.each_slice(PAGE_SIZE).to_a
    end

    def page_body(slice, index, total)
      more = index < total - 1
      { data: { orders: { nodes: slice.map { |number| { id: gid(number) } },
                          pageInfo: { hasNextPage: more, endCursor: more ? "p#{index + 1}" : nil } } } }
    end

    def arrange_pages(shop, failing: nil)
      all = pages(shop)
      all.each_with_index do |slice, index|
        after = index.zero? ? nil : "p#{index}"
        body = page_body(slice, index, all.size)
        if index == failing
          admin = @fixture.admin
          admin.arrange(shop, "ReconcileOrders", after, { errors: [{ message: "fuzz outage" }] }, code: 500) do
            admin.arrange(shop, "ReconcileOrders", after, body)
          end
        else
          @fixture.admin.arrange(shop, "ReconcileOrders", after, body)
        end
      end
    end

    def receive(shop, webhook_id, topic, order_id)
      ShopifyLedger::Inbox.new(@storages[@config.database_for(shop)]).receive(shop: shop, webhook_id: webhook_id, topic: topic, order_id: order_id)
    end

    def op_deliver(a, b, c)
      shop, number = order_key(a, b)
      topic = (c % 4).zero? ? "refunds/create" : "orders/updated"
      webhook = [shop, "w#{@webhooks.size + 1}", topic, gid(number)]
      fail!("new delivery was not inserted") unless receive(*webhook)
      @webhooks << webhook
    end

    def op_duplicate(a, _b, _c)
      webhook = pick(@webhooks, a) or return
      fail!("duplicate delivery #{webhook[1]} was inserted twice") if receive(*webhook)
    end

    def database(value) = @config.all_databases[value % @config.all_databases.size]
    def each_storage(&block) = @config.all_databases.map { |path| @storages[path].connect(&block) }
    def worker(path = @config.database) = ShopifyLedger::Worker.new(@config, database: path)

    def run_worker(a, **hooks)
      outcome = worker(database(a)).run_once(**hooks)
      fail!("unexpected worker outcome #{outcome.inspect}") unless %w[idle processed retry parked].include?(outcome)
      outcome
    rescue Crash
      "crashed"
    end

    def op_worker(a, *) = run_worker(a)
    def op_crash_before_commit(a, *) = run_worker(a, before_commit: -> { raise Crash })
    def op_crash_after_commit(a, *) = run_worker(a, after_commit: -> { raise Crash })

    # Moves a shop to the other database, sometimes crashing after the copy or the switch.
    def op_move_shop(a, _b, c)
      shop = SHOPS[a % SHOPS.size]
      to = route_name(shop) == "eu" ? "main" : "eu"
      seam = [nil, :after_copy, :after_switch][c % 3]
      hooks = seam ? { seam => -> { raise Crash } } : {}
      begin
        ShopifyLedger::MoveShop.run(@config_path, shop, to, **hooks)
      rescue Crash
        nil
      rescue ShopifyLedger::MoveShop::Refused => error
        fail!("move refused: #{error.message}")
      end
      @config = ShopifyLedger::Config.load
    end

    def route_name(shop) = JSON.parse(File.read(@config_path)).dig("shops", shop, "database") || "main"

    def op_orphan_claim(a, b, _c)
      @storages[database(b)].connect do |db|
        ids = db.execute("SELECT id FROM inbox WHERE processed = 0 AND parked_at IS NULL ORDER BY id").flatten
        id = pick(ids, a) or next
        db.execute("UPDATE inbox SET claimed_by = ?, claimed_until = ? WHERE id = ?", [@dead_pid, Time.now.to_i + 3600, id])
      end
    end

    def op_admin_fault(a, b, c)
      shop, number = order_key(a, b)
      code, body = [[429, { errors: [{ message: "Throttled" }] }],
                    [500, { errors: [{ message: "fuzz" }] }],
                    [200, { errors: [{ message: "Throttled", extensions: { code: "THROTTLED" } }] }],
                    [503, "<html>unavailable</html>"]][c % 4]
      admin = @fixture.admin
      truth = order_body(shop, number)
      admin.arrange(shop, "OrderPayments", gid(number), body, code: code) do
        admin.arrange(shop, "OrderPayments", gid(number), truth)
      end
    end

    # Admin reads can lag: one fetch answers with an earlier state of the order.
    def op_admin_stale_read(a, b, c)
      shop, number = order_key(a, b)
      history = @orders.fetch([shop, number])[:history]
      return if history.empty?

      old = history[c % history.size]
      admin = @fixture.admin
      truth = order_body(shop, number)
      body = { data: { order: { id: gid(number), transactions: old,
                                transactionsCount: { count: old.size, precision: "EXACT" } } } }
      admin.arrange(shop, "OrderPayments", gid(number), body) do
        admin.arrange(shop, "OrderPayments", gid(number), truth)
      end
    end

    def op_mutate(a, b, c)
      shop, number = order_key(a, b)
      order = @orders.fetch([shop, number])
      kind = %w[SALE SALE CAPTURE REFUND REFUND AUTHORIZATION VOID][c % 7]
      status = if (c % 11).zero? then "FAILURE" elsif (c % 13).zero? then "ERROR" elsif (c % 5).zero? then "PENDING" else "SUCCESS" end
      id = "gid://shopify/OrderTransaction/#{@counters[shop] += 1}"
      cents = (c / 7) % 10_000_000
      amount = format("%d.%02d", cents / 100, cents % 100)
      amount = "#{amount}#{c % 10}" if order[:currency] == "BHD"
      # Buyers may pay in another currency; that amount is stored, never converted.
      presentment = (c / 17).even? ? [amount, order[:currency]] : [format("%d.%02d", cents / 70, cents % 100), "EUR"]
      authorizations = order[:transactions].select { |existing| existing[:kind] == "AUTHORIZATION" }
      parent = pick(authorizations, c)&.fetch(:id) if %w[CAPTURE VOID].include?(kind)
      order[:transactions] << ShopifyFixture.transaction(id, kind, amount, order[:currency], status,
                                                         presentment: presentment, parent: parent)
      @truth[[shop, id]] = { order: gid(number), kind: kind, status: status, amount: amount, currency: order[:currency],
                             presentment: presentment, parent: parent }
      arrange_truth(shop, number)
      # Shopify usually, but not always, sends a webhook for the change.
      op_deliver(a, b, (c / 3) % 4 * 3 + 1) unless (b % 4).zero?
    end

    def op_complete_pending(a, b, c)
      pending = @truth.select { |_key, truth| truth[:status] == "PENDING" }.keys.sort
      choice = pick(pending, a) or return
      shop, id = choice
      truth = @truth.fetch([shop, id])
      number = Integer(truth[:order].split("/").last)
      truth[:status] = "SUCCESS"
      order = @orders.fetch([shop, number])
      order[:transactions].map! { |existing| existing[:id] == id ? existing.merge(status: "SUCCESS") : existing }
      arrange_truth(shop, number)
      op_deliver(SHOPS.index(shop), number - 1, (c % 3) + 1) unless (b % 4).zero?
    end

    def op_advance_time(*)
      each_storage { |db| db.execute("UPDATE inbox SET next_attempt_at = 0 WHERE processed = 0") }
    end

    def op_operator_retry(a, _b, _c)
      parked = routed_parked
      choice = pick(parked, a) or return
      shop, webhook_id = choice
      ShopifyLedger::Deliveries.new(@config).retry(shop, webhook_id)
    end

    # Parked deliveries in each shop's routed database (stale copies elsewhere are not live).
    def routed_parked
      @config.all_databases.flat_map do |path|
        rows = @storages[path].connect { |db| db.execute("SELECT shop, webhook_id FROM inbox WHERE parked_at IS NOT NULL ORDER BY id") }
        rows.select { |shop, _| @config.database_for(shop) == path }
      end
    end

    def reconcile(shop)
      @clock += 600
      ShopifyLedger::Reconciliation.new(@config, clock: -> { @clock }).run(shop)
      true
    rescue ShopifyLedger::Admin::Error, ShopifyLedger::Payments::Error
      false
    end

    def op_reconcile(a, _b, _c) = reconcile(SHOPS[a % SHOPS.size])

    def op_reconcile_failing_page(a, b, _c)
      shop = SHOPS[a % SHOPS.size]
      arrange_pages(shop, failing: b % pages(shop).size)
      reconcile(shop)
    end

    def op_backup(*)
      path = File.join(File.dirname(@fixture.database), "backup-#{@backups += 1}.sqlite3")
      report = ShopifyLedger::Backup.new(@config).create(path)
      fail!("backup integrity #{report[:integrity]}") unless report[:integrity] == "ok"
      check_invariants(path, live: false)
    end

    def op_maintain(*) = ShopifyLedger::Maintenance.run(@config)

    def op_drain_processes(a, _b, _c)
      workers = Array.new(2 + (a % 3)) do |machine|
        ENV["SHOPIFY_LEDGER_WORKER_ID"] = "machine-#{machine}"
        @fixture.spawn(worker_executable, "--drain")
      ensure
        ENV.delete("SHOPIFY_LEDGER_WORKER_ID")
      end
      workers.each do |stdin, stdout, stderr, waiter|
        stdin.close
        output = stdout.read
        stderr.read
        fail!("drain process failed: #{output}") unless waiter.value.exited? && [0, 1].include?(waiter.value.exitstatus)
      end
    end

    def worker_executable = "bin/shopify-worker"

    def op_kill_mid_fetch(*)
      admin = @fixture.admin
      before = admin.requests.size
      stdin, stdout, stderr, waiter = @fixture.spawn(worker_executable, "--once")
      stdin.close
      deadline = Time.now + 3
      sleep 0.01 until admin.requests.size > before || Time.now > deadline || !waiter.alive?
      Process.kill("KILL", waiter.pid) if waiter.alive?
      waiter.value
      stdout.read
      stderr.read
    rescue Errno::ESRCH
      nil
    end

    # Not generated: lets tests prove the oracle notices a wrong stored amount.
    def op_plant_wrong_amount(*)
      @storages[@config.database].connect do |db|
        db.execute("UPDATE transactions SET amount = amount || '1' WHERE rowid = (SELECT MIN(rowid) FROM transactions)")
      end
    end

    def expected_row(shop, transaction_id)
      truth = @truth[[shop, transaction_id]]
      return unless truth && truth[:status] == "SUCCESS" && ShopifyLedger::Payments::PAYMENT_KINDS.include?(truth[:kind])

      amount = BigDecimal(truth[:amount])
      format = ShopifyLedger::Payments.method(:format_decimal)
      [truth[:order], truth[:currency], truth[:kind], format.call(amount.abs),
       truth[:presentment][1], format.call(BigDecimal(truth[:presentment][0])), truth[:parent]]
    end

    EVENTS_SQL = "SELECT shop, transaction_id, kind, status, amount, presentment_currency FROM payment_events".freeze

    # Invariants 1 and 2 plus payment statuses, for rows read from any backend.
    def verify_rows(rows, events)
      keys = rows.map { |row| row.first(2) }
      fail!("a (shop, transaction_id) is stored twice") unless keys.uniq.size == keys.size
      rows.each do |shop, transaction_id, *stored|
        expected = expected_row(shop, transaction_id)
        fail!("stored #{shop} #{transaction_id} #{stored.inspect} is not in the ground truth (expected #{expected.inspect})") unless stored == expected
      end
      events.each do |shop, id, kind, status, amount, presentment|
        truth = @truth[[shop, id]]
        fail!("seen transaction #{shop} #{id} is not in the ground truth") unless truth
        same = [kind, amount, presentment] == [truth[:kind], ShopifyLedger::Payments.format_decimal(BigDecimal(truth[:amount]).abs), truth[:presentment][1]]
        fail!("seen transaction #{id} differs from the ground truth") unless same
        # A stored status may lag the ground truth (an open status), but never contradict it.
        unless status == truth[:status] || !ShopifyLedger::Payments::FINAL_STATUSES.include?(status)
          fail!("transaction #{id} stored as #{status} but Shopify says #{truth[:status]}")
        end
      end
    end

    def check_invariants(path, live: true)
      # A SIGKILLed worker can leave a hot journal that only a writable connection may roll back.
      db = SQLite3::Database.new(path)
      db.busy_timeout(5000)
      rows = db.execute(<<~SQL)
        SELECT shop, transaction_id, order_id, currency, kind, amount, presentment_currency, presentment_amount,
               parent_transaction_id
        FROM transactions
      SQL
      verify_rows(rows, db.execute(EVENTS_SQL))
      both = db.get_first_value("SELECT COUNT(*) FROM inbox WHERE processed = 1 AND parked_at IS NOT NULL")
      fail!("#{both} deliveries are both processed and parked") unless both.zero?
      claimed = db.get_first_value("SELECT COUNT(*) FROM inbox WHERE processed = 1 AND claimed_by IS NOT NULL")
      fail!("#{claimed} processed deliveries still hold a claim") unless claimed.zero?
      db.execute("SELECT DISTINCT claimed_by FROM inbox WHERE claimed_by IS NOT NULL").flatten.each do |pid|
        # A crash injected in this process leaves its own PID, which workers treat as dead.
        next if pid == Process.pid || pid == @dead_pid

        alive = begin
          Process.kill(0, pid)
          true
        rescue Errno::ESRCH
          false
        end
        fail!("claim points at live process #{pid} that is not a worker") if alive
      end
      return unless live

      db.execute("SELECT shop, synced_through FROM checkpoints").each do |shop, synced|
        next unless @config.database_for(shop) == path

        previous = @checkpoints[shop]
        fail!("checkpoint for #{shop} moved backwards from #{previous} to #{synced}") if previous && synced < previous
        @checkpoints[shop] = synced
      end
    ensure
      db&.close
    end

    def settle
      @orders.each_key { |key| arrange_truth(*key) }
      SHOPS.each { |shop| arrange_pages(shop) }
      # Finish any move that crashed: the rerun only cleans up stale copies.
      SHOPS.each { |shop| ShopifyLedger::MoveShop.run(@config_path, shop, route_name(shop)) }
      @config = ShopifyLedger::Config.load
      10.times do
        routed_parked.each { |shop, webhook_id| ShopifyLedger::Deliveries.new(@config).retry(shop, webhook_id) }
        op_advance_time
        @config.all_databases.each do |path|
          counts = worker(path).drain
          fail!("settle drain #{counts.inspect}") if counts["status"] == "storage_error"
        end
        break if each_storage { |db| db.get_first_value("SELECT COUNT(*) FROM inbox WHERE processed = 0") }.sum.zero?
      end
      SHOPS.each do |shop|
        fail!("settle reconciliation failed for #{shop}") unless reconcile(shop)
      end
      @config.all_databases.each { |path| check_invariants(path) }
      @config.all_databases.each do |path|
        @storages[path].connect do |db|
          pending = db.get_first_value("SELECT COUNT(*) FROM inbox WHERE processed = 0")
          fail!("#{pending} deliveries never completed in #{File.basename(path)}") unless pending.zero?
          stale = db.execute("SELECT shop, transaction_id, status FROM payment_events")
                    .reject { |shop, id, status| @truth.fetch([shop, id])[:status] == status }
          fail!("statuses still lag after settle: #{stale.first(3).inspect}") unless stale.empty?
          SHOPS.each do |shop|
            stored = db.execute("SELECT transaction_id FROM transactions WHERE shop = ?", [shop]).flatten.to_set
            unless @config.database_for(shop) == path
              fail!("#{shop} still has rows in #{File.basename(path)} after its move") unless stored.empty?
              next
            end
            expected = @truth.keys.select { |truth_shop, id| truth_shop == shop && expected_row(shop, id) }.to_set { |_, id| id }
            fail!("missing after settle: #{(expected - stored).to_a.first(3).inspect}") unless (expected - stored).empty?
            fail!("totals for #{shop} differ from the model") unless ShopifyLedger::Payments.summary(db, shop) == model_totals(shop)
          end
        end
      end
    end

    def model_totals(shop)
      sums = Hash.new { |hash, currency| hash[currency] = [BigDecimal("0"), BigDecimal("0")] }
      @truth.each do |(truth_shop, id), truth|
        next unless truth_shop == shop && expected_row(shop, id)

        sums[truth[:currency]][truth[:kind] == "REFUND" ? 1 : 0] += BigDecimal(truth[:amount]).abs
      end
      format = ShopifyLedger::Payments.method(:format_decimal)
      sums.sort.map do |currency, (collected, refunded)|
        { "currency" => currency, "collected" => format.call(collected), "refunded" => format.call(refunded),
          "net" => format.call(collected - refunded) }
      end
    end
  end

  # The same operation lists against the PostgreSQL worker. Reconciliation,
  # backups, maintenance and moves are SQLite-only, so they do nothing here;
  # settle instead sends one final webhook per order, as Shopify would.
  class PostgresExecution < Execution
    URL = ENV["SHOPIFY_LEDGER_POSTGRES_URL"]

    private

    def setup(orders)
      super
      require_relative "../../lib/shopify_ledger/postgres"
      @pg&.close
      @pg = ShopifyLedger::Postgres::Database.new(URL || raise(ArgumentError, "set SHOPIFY_LEDGER_POSTGRES_URL"))
      @pg.execute("DROP TABLE IF EXISTS inbox, transactions, payment_events")
      @pg.migrate
    end

    def receive(shop, webhook_id, topic, order_id)
      ShopifyLedger::Postgres.receive(@pg, shop: shop, webhook_id: webhook_id, topic: topic, order_id: order_id)
    end

    def pg_worker(owner = "fuzz-machine") = ShopifyLedger::Postgres::Worker.new(@config, @pg, owner: owner)

    def run_worker(_a, **hooks)
      outcome = pg_worker.run_once(**hooks)
      fail!("unexpected worker outcome #{outcome.inspect}") unless %w[idle processed retry parked].include?(outcome)
      outcome
    rescue Crash
      "crashed"
    end

    # A worker on another machine died holding a lease.
    def op_orphan_claim(a, _b, _c)
      ids = @pg.execute("SELECT id FROM inbox WHERE processed = 0 AND parked_at IS NULL ORDER BY id").flatten
      id = pick(ids, a) or return
      @pg.execute("UPDATE inbox SET claimed_by = 'dead-machine', claimed_until = ? WHERE id = ?", [Time.now.to_i + 60, id])
    end

    # Time passes: backoffs and leases expire.
    def op_advance_time(*)
      @pg.execute(<<~SQL)
        UPDATE inbox SET next_attempt_at = 0,
                         claimed_until = CASE WHEN claimed_until IS NULL THEN NULL ELSE 0 END
        WHERE processed = 0
      SQL
    end

    def op_operator_retry(a, _b, _c)
      ids = @pg.execute("SELECT id FROM inbox WHERE parked_at IS NOT NULL ORDER BY id").flatten
      id = pick(ids, a) or return
      @pg.execute("UPDATE inbox SET parked_at = NULL, attempts = 0, next_attempt_at = 0, last_error = NULL WHERE id = ?", [id])
    end

    def worker_executable = "bin/shopify-pg-worker"

    %w[reconcile reconcile_failing_page backup maintain move_shop].each do |op|
      define_method("op_#{op}") { |*| nil }
    end

    def check_invariants(path, live: true)
      return unless path == @config.database

      rows = @pg.execute(<<~SQL)
        SELECT shop, transaction_id, order_id, currency, kind, amount, presentment_currency, presentment_amount,
               parent_transaction_id
        FROM transactions
      SQL
      verify_rows(rows, @pg.execute(EVENTS_SQL))
      claimed = @pg.get_first_value("SELECT COUNT(*) FROM inbox WHERE processed = 1 AND claimed_by IS NOT NULL")
      fail!("#{claimed} processed deliveries still hold a lease") unless claimed.zero?
    end

    def settle
      @orders.each_key { |key| arrange_truth(*key) }
      @orders.each do |(shop, number), order|
        receive(shop, "settle-#{number}", "orders/updated", gid(number)) unless order[:transactions].empty?
      end
      10.times do
        @pg.execute("UPDATE inbox SET parked_at = NULL, attempts = 0 WHERE parked_at IS NOT NULL")
        op_advance_time
        pg_worker("settle-machine").drain
        break if @pg.get_first_value("SELECT COUNT(*) FROM inbox WHERE processed = 0").zero?
      end
      check_invariants(@config.database)
      pending = @pg.get_first_value("SELECT COUNT(*) FROM inbox WHERE processed = 0")
      fail!("#{pending} deliveries never completed") unless pending.zero?
      stale = @pg.execute("SELECT shop, transaction_id, status FROM payment_events")
                 .reject { |shop, id, status| @truth.fetch([shop, id])[:status] == status }
      fail!("statuses still lag after settle: #{stale.first(3).inspect}") unless stale.empty?
      stored = @pg.execute("SELECT shop, transaction_id FROM transactions").to_set
      expected = @truth.keys.select { |shop, id| expected_row(shop, id) }.to_set
      fail!("missing after settle: #{(expected - stored).to_a.first(3).inspect}") unless (expected - stored).empty?
      SHOPS.each do |shop|
        fail!("totals for #{shop} differ from the model") unless ShopifyLedger::Payments.summary(@pg, shop) == model_totals(shop)
      end
    ensure
      @pg&.close
      @pg = nil
    end
  end
end
