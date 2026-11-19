require "json"

module ShopifyLedger
  module StrictJSON
    # Some Ruby JSON versions accept comments, invalid escapes, and lone surrogates.
    # Validate the string lexemes before the parser checks the object structure.
    HEX = /[0-9A-Fa-f]/
    BMP = /(?:[0-9A-Ca-cE-Fe-f]#{HEX}{3}|[Dd][0-7]#{HEX}{2})/
    SURROGATE_PAIR = /[Dd][89A-Ba-b]#{HEX}{2}\\u[Dd][C-Fc-f]#{HEX}{2}/
    JSON_LEXEMES = %r{\A(?:[^"/\\]++|"(?:[^"\\\x00-\x1f]++|\\(?:["\\/bfnrt]|u(?:#{BMP}|#{SURROGATE_PAIR})))*+")*+\z}

    class UniqueKeys < Hash
      def []=(key, value)
        raise JSON::ParserError, "duplicate JSON key" if key?(key)

        super
      end
    end
    private_constant :UniqueKeys

    def self.parse(raw)
      text = raw.dup.force_encoding(Encoding::UTF_8)
      unless text.valid_encoding? && JSON_LEXEMES.match?(text)
        raise JSON::ParserError, "invalid JSON lexeme"
      end

      JSON.parse(text, object_class: UniqueKeys)
    end
  end
end
