require "json"
require_relative "crash_harness"

module LedgerProcess
  ROOT = File.expand_path("../..", __dir__).freeze
  ENTRY = File.join(ROOT, "bin/ledger").freeze
  HOOK_ENTRY = File.join(ROOT, "test/support/ledger-with-hooks").freeze

  def self.deliver(sequence, delta, **options)
    { op: "deliver", seq: sequence, delta: delta }.merge(options)
  end

  def self.database(directory)
    File.join(directory, "ledger.sqlite3")
  end

  def self.run(directory, request, entry: ENTRY)
    input = request.is_a?(String) ? request : JSON.generate(request)
    CrashHarness.capture(directory, entry, input: input)
  end

  def self.response(directory, request, entry: ENTRY)
    stdout, stderr, status = run(directory, request, entry: entry)
    unless status.success? && stderr.empty?
      raise "#{entry} #{request.inspect}: expected exit 0 and empty stderr, got " \
            "#{status.inspect}, stdout=#{stdout.inspect}, stderr=#{stderr.inspect}"
    end
    JSON.parse(stdout)
  rescue JSON::ParserError => error
    raise "#{entry} #{request.inspect}: invalid response #{stdout.inspect} (#{error.message})"
  end

  def self.snapshot(directory)
    path = database(directory)
    raise "missing database at #{path}" unless File.file?(path)

    db = SQLite3::Database.new(path)
    db.execute("BEGIN")
    {
      "events" => db.execute("SELECT seq, delta FROM events ORDER BY seq"),
      "checkpoint" => db.get_first_row("SELECT cursor, balance FROM checkpoint")
    }
  ensure
    db&.close
  end
end
