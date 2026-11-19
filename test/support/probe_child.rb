require_relative "../../lib/event_consumer/bundle"
require "sqlite3"

STDOUT.sync = true
seam = ARGV.fetch(0)
abort "unknown seam: #{seam}" unless %w[before_commit after_commit_before_ack].include?(seam)

SQLite3::Database.new("probe.sqlite3") do |db|
  db.execute("BEGIN IMMEDIATE")
  db.execute("UPDATE checkpoint SET cursor = 3")
  db.execute("UPDATE checkpoint SET balance = '6'")
  Process.kill("KILL", Process.pid) if seam == "before_commit"
  db.execute("COMMIT")
  Process.kill("KILL", Process.pid)
end
