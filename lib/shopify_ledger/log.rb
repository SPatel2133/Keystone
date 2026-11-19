require "json"

module ShopifyLedger
  # One JSON object per line on stderr. Callers pass identifiers and outcomes
  # only: never tokens, secrets or webhook bodies.
  module Log
    def self.event(name, **fields)
      $stderr.puts(JSON.generate({ event: name, at: Time.now.utc.iso8601 }.merge(fields)))
    rescue IOError, SystemCallError
      nil
    end
  end
end
