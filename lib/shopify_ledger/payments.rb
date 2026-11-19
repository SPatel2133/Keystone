require "bigdecimal"

module ShopifyLedger
  module Payments
    class Error < StandardError; end

    STATUSES = %w[AWAITING_RESPONSE ERROR FAILURE PENDING SUCCESS UNKNOWN].freeze
    PAYMENT_KINDS = %w[SALE CAPTURE REFUND].freeze
    KINDS = (PAYMENT_KINDS + %w[AUTHORIZATION CHANGE EMV_AUTHORIZATION SUGGESTED_REFUND VOID]).freeze
    # CurrencyCode in Admin GraphQL 2026-10, including its deprecated valid values.
    CURRENCIES = %w[
      AED AFN ALL AMD ANG AOA ARS AUD AWG AZN BAM BBD BDT BGN BHD BIF
      BMD BND BOB BRL BSD BTN BWP BYN BYR BZD CAD CDF CHF CLP CNY COP
      CRC CVE CZK DJF DKK DOP DZD EGP ERN ETB EUR FJD FKP GBP GEL GHS
      GIP GMD GNF GTQ GYD HKD HNL HRK HTG HUF IDR ILS INR IQD IRR ISK
      JEP JMD JOD JPY KES KGS KHR KID KMF KRW KWD KYD KZT LAK LBP LKR
      LRD LSL LTL LVL LYD MAD MDL MGA MKD MMK MNT MOP MRU MUR MVR MWK
      MXN MYR MZN NAD NGN NIO NOK NPR NZD OMR PAB PEN PGK PHP PKR PLN
      PYG QAR RON RSD RUB RWF SAR SBD SCR SDG SEK SGD SHP SLL SOS SRD
      SSP STD STN SYP SZL THB TJS TMT TND TOP TRY TTD TWD TZS UAH UGX
      USD USDC UYU UZS VED VEF VES VND VUV WST XAF XCD XCG XOF XPF XXX
      YER ZAR ZMW
    ].freeze

    def self.entries(transactions)
      transactions.each_with_object([]) do |transaction, entries|
        status = transaction["status"]
        kind = transaction["kind"]
        raise Error, "Invalid transaction status or kind" unless STATUSES.include?(status) && KINDS.include?(kind)

        amount_set = transaction["amountSet"]
        money = amount_set["shopMoney"] if amount_set.is_a?(Hash)
        currency = money["currencyCode"] if money.is_a?(Hash)
        amount = money["amount"] if money.is_a?(Hash)
        unless CURRENCIES.include?(currency) &&
               amount.is_a?(String) && amount.match?(/\A-?\d+(?:\.\d+)?\z/)
          raise Error, "Invalid shopMoney amount or currency"
        end

        next unless status == "SUCCESS" && PAYMENT_KINDS.include?(kind)

        decimal = BigDecimal(amount)
        decimal = decimal.abs if kind == "REFUND"
        raise Error, "Negative sale or capture amount" if decimal.negative?

        entries << [transaction.fetch("id"), currency, kind, format_decimal(decimal)]
      end
    end

    # Returns the number of newly recorded payment transactions. The source names
    # the delivery or reconciliation run that first established each row.
    def self.apply(db, shop, order_id, entries, source: nil)
      recorded_at = Time.now.to_i
      entries.count do |transaction_id, currency, kind, amount|
        stored = db.get_first_row(<<~SQL, [shop, transaction_id])
          SELECT order_id, currency, kind, amount
          FROM transactions WHERE shop = ? AND transaction_id = ?
        SQL
        values = [order_id, currency, kind, amount]
        next false if stored == values

        if stored
          stored_order, stored_currency, stored_kind, stored_amount = stored
          unless !CURRENCIES.include?(stored_currency) &&
                 [stored_order, stored_kind, stored_amount] == [order_id, kind, amount]
            raise Error, "Previously recorded transaction details conflict"
          end

          # Older ledgers accepted arbitrary three- or four-letter currency codes.
          db.execute("UPDATE transactions SET currency = ? WHERE shop = ? AND transaction_id = ?",
                     [currency, shop, transaction_id])
          next false
        end

        db.execute(<<~SQL, [shop, transaction_id, *values, recorded_at, source])
          INSERT INTO transactions (shop, transaction_id, order_id, currency, kind, amount, recorded_at, source)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        SQL
        true
      end
    end

    def self.summary(db, shop)
      totals = Hash.new { |hash, currency| hash[currency] = [BigDecimal("0"), BigDecimal("0")] }
      db.execute("SELECT currency, kind, amount FROM transactions WHERE shop = ?", [shop]) do |currency, kind, amount|
        raise Error, "Stored payment has invalid currency; reconcile its order" unless CURRENCIES.include?(currency)

        index = kind == "REFUND" ? 1 : 0
        totals[currency][index] += BigDecimal(amount)
      end
      totals.sort.map do |currency, (collected, refunded)|
        {
          "currency" => currency,
          "collected" => format_decimal(collected),
          "refunded" => format_decimal(refunded),
          "net" => format_decimal(collected - refunded)
        }
      end
    end

    def self.format_decimal(decimal)
      whole, fraction = (decimal.zero? ? BigDecimal("0") : decimal).to_s("F").split(".", 2)
      # sqlite3 1.3 binds ASCII-8BIT strings as BLOBs.
      "#{whole}.#{fraction.to_s.ljust(2, "0")}".encode(Encoding::UTF_8)
    end
    private_class_method :format_decimal
  end
end
