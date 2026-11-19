Gem::Specification.new do |spec|
  spec.name = "sequence-ledger"
  spec.version = "0.1.0"
  spec.summary = "A crash-safe SQLite consumer for sequenced integer adjustments"
  spec.authors = ["Satyam Patel"]
  spec.homepage = "https://github.com/SPatel2133/ruby-event-consumer"
  spec.license = "Nonstandard"
  spec.required_ruby_version = "~> 3.4.0"
  spec.files = %w[exe/sequence-ledger lib/event_consumer/cli.rb lib/event_consumer/request.rb lib/event_consumer/ledger.rb]
  spec.bindir = "exe"
  spec.executables = ["sequence-ledger"]
  spec.add_runtime_dependency "sqlite3", "~> 2.0"
end
