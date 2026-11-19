require "open3"
require "rbconfig"
require "sqlite3"
require "tmpdir"

module CrashHarness
  SEAMS = %w[before_commit after_commit_before_ack].freeze
  CLEAN_ENV = { "BUNDLE_GEMFILE" => nil, "RUBYOPT" => nil }.freeze

  def self.capture(directory, executable, *arguments, input: "")
    Open3.capture3(CLEAN_ENV, [executable, executable], *arguments,
                   stdin_data: input, binmode: true, chdir: directory)
  end

  def self.observation(stdout, stderr, status)
    {
      "signal" => status.termsig,
      "stdout_bytes" => stdout.bytes,
      "stderr" => stderr
    }
  end

  def self.killed
    { "signal" => Signal.list.fetch("KILL"), "stdout_bytes" => [], "stderr" => "" }
  end

  def self.probe(seam)
    Dir.mktmpdir("ledger-probe-") do |directory|
      path = File.join(directory, "probe.sqlite3")
      SQLite3::Database.new(path) do |db|
        db.execute("CREATE TABLE checkpoint (cursor INTEGER, balance TEXT)")
        db.execute("INSERT INTO checkpoint VALUES (1, '5')")
      end
      child = File.expand_path("probe_child.rb", __dir__)
      stdout, stderr, status = capture(directory, RbConfig.ruby, child, seam)
      checkpoint = nil
      SQLite3::Database.new(path) do |db|
        checkpoint = db.get_first_row("SELECT cursor, balance FROM checkpoint")
      end
      {
        "type" => "harness_probe",
        "seam" => seam,
        "expected" => killed.merge("checkpoint" => seam == "before_commit" ? [1, "5"] : [3, "6"]),
        "observed" => observation(stdout, stderr, status).merge("checkpoint" => checkpoint)
      }
    end
  end
end
