require_relative "bundle"
require_relative "ledger"

module EventConsumer
  module CLI
    def self.run(hooks: {})
      STDOUT.sync = true
      request = Request.parse(STDIN.binmode.read, hooks)
      response = request ? Ledger.new.call(request, hooks) : { error: "invalid_request" }
      STDOUT.write(JSON.generate(response) + "\n")
      0
    rescue StandardError => error
      warn "ledger: #{error.class}: #{error.message}"
      1
    end
  end
end
