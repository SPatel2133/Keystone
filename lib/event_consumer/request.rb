require "json"

module EventConsumer
  MAX_INTEGER = (2**63) - 1
  MIN_INTEGER = -(2**63)

  module Request
    # Every valid request is a flat object containing only strings and integers.
    # Ruby 2.6's JSON parser also accepts comments, so check the wire grammar first.
    STRING = /"(?:[^"\\\x00-\x1f]|\\(?:["\\\/bfnrt]|u[0-9a-fA-F]{4}))*+"/
    INTEGER = /-?(?:0|[1-9][0-9]*+)/
    SPACE = /[ \t\r\n]*/
    MEMBER = /#{STRING}#{SPACE}:#{SPACE}(?:#{STRING}|#{INTEGER})/
    OBJECT = /\A#{SPACE}\{#{SPACE}(?:#{MEMBER}#{SPACE}(?:,#{SPACE}#{MEMBER}#{SPACE})*)?\}#{SPACE}\z/

    class UniqueFields < Hash
      def []=(key, value)
        raise JSON::ParserError, "duplicate request field" if key?(key)

        super
      end
    end

    def self.parse(raw, hooks)
      raw = raw.dup.force_encoding(Encoding::UTF_8)
      return unless raw.valid_encoding? && OBJECT.match?(raw)

      fields = JSON.parse(raw, object_class: UniqueFields)
      case fields["op"]
      when "state"
        fields if fields.keys == ["op"]
      when "deliver"
        keys = fields.keys.sort
        return unless keys == %w[delta op seq] ||
                      (keys == %w[delta hook op seq] && hooks.key?(fields["hook"]))
        return unless fields["seq"].is_a?(Integer) && fields["seq"].between?(1, MAX_INTEGER)
        return unless fields["delta"].is_a?(Integer) && fields["delta"].between?(MIN_INTEGER, MAX_INTEGER)

        fields
      end
    rescue JSON::ParserError
      nil
    end
  end
end
