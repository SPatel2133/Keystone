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

    # A transaction's status only moves from an open status to a final one.
    FINAL_STATUSES = %w[SUCCESS FAILURE ERROR].freeze
    AMOUNT = /\A-?\d+(?:\.\d+)?\z/

    Entry = Struct.new(:id, :kind, :status, :currency, :amount, :presentment_currency, :presentment_amount, :parent,
                       keyword_init: true) do
      def balance? = status == "SUCCESS" && PAYMENT_KINDS.include?(kind)
    end

    def self.money(amount_set, key)
      money = amount_set[key] if amount_set.is_a?(Hash)
      currency = money["currencyCode"] if money.is_a?(Hash)
      amount = money["amount"] if money.is_a?(Hash)
      raise Error, "Invalid #{key} amount or currency" unless CURRENCIES.include?(currency) && amount.is_a?(String) && amount.match?(AMOUNT)

      [currency, BigDecimal(amount)]
    end

    def self.entries(transactions)
      entries = transactions.map do |transaction|
        status = transaction["status"]
        kind = transaction["kind"]
        raise Error, "Invalid transaction status or kind" unless STATUSES.include?(status) && KINDS.include?(kind)

        currency, amount = money(transaction["amountSet"], "shopMoney")
        presentment_currency, presentment_amount = money(transaction["amountSet"], "presentmentMoney")
        # Different currencies are never converted; the same currency must agree exactly.
        if presentment_currency == currency && presentment_amount != amount
          raise Error, "Presentment and shop amounts differ in the same currency"
        end
        if %w[SALE CAPTURE AUTHORIZATION].include?(kind) && amount.negative?
          raise Error, "Negative #{kind.downcase} amount"
        end

        parent = transaction["parentTransaction"]
        parent_id = parent["id"] if parent.is_a?(Hash)
        raise Error, "Invalid parent transaction" unless parent.nil? || parent_id.is_a?(String)

        Entry.new(id: transaction.fetch("id"), kind: kind, status: status, currency: currency,
                  amount: format_decimal(amount.abs), presentment_currency: presentment_currency,
                  presentment_amount: format_decimal(presentment_amount.abs), parent: parent_id)
      end
      by_id = entries.to_h { |entry| [entry.id, entry] }
      entries.each do |entry|
        parent = by_id[entry.parent]
        next unless parent && parent.currency != entry.currency

        raise Error, "#{entry.kind} #{entry.id} is in #{entry.currency} but its parent is in #{parent.currency}"
      end
      entries
    end

    # Records every transaction's latest status, then returns the number of newly
    # recorded SUCCESS payments. The source names the delivery or reconciliation
    # run that first established each payment row.
    def self.apply(db, shop, order_id, entries, source: nil)
      recorded_at = Time.now.to_i
      entries.each { |entry| observe(db, shop, order_id, entry, recorded_at) }
      entries.select(&:balance?).count do |entry|
        stored = db.get_first_row(<<~SQL, [shop, entry.id])
          SELECT order_id, currency, kind, amount, presentment_currency
          FROM transactions WHERE shop = ? AND transaction_id = ?
        SQL
        values = [order_id, entry.currency, entry.kind, entry.amount]
        details = [entry.presentment_currency, entry.presentment_amount, entry.parent]
        if stored&.first(4) == values
          # Rows recorded before presentment money was stored gain it now.
          if stored.last.nil?
            db.execute(<<~SQL, [*details, shop, entry.id])
              UPDATE transactions SET presentment_currency = ?, presentment_amount = ?, parent_transaction_id = ?
              WHERE shop = ? AND transaction_id = ?
            SQL
          end
          next false
        end

        if stored
          stored_order, stored_currency, stored_kind, stored_amount = stored
          unless !CURRENCIES.include?(stored_currency) &&
                 [stored_order, stored_kind, stored_amount] == [order_id, entry.kind, entry.amount]
            raise Error, "Previously recorded transaction details conflict"
          end

          # Older ledgers accepted arbitrary three- or four-letter currency codes.
          db.execute(<<~SQL, [entry.currency, *details, shop, entry.id])
            UPDATE transactions SET currency = ?, presentment_currency = ?, presentment_amount = ?, parent_transaction_id = ?
            WHERE shop = ? AND transaction_id = ?
          SQL
          next false
        end

        db.execute(<<~SQL, [shop, entry.id, *values, recorded_at, source, *details])
          INSERT INTO transactions (shop, transaction_id, order_id, currency, kind, amount, recorded_at, source,
                                    presentment_currency, presentment_amount, parent_transaction_id)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        SQL
        true
      end
    end

    def self.observe(db, shop, order_id, entry, now)
      facts = [order_id, entry.kind, entry.currency, entry.amount, entry.presentment_currency,
               entry.presentment_amount, entry.parent]
      stored = db.get_first_row(<<~SQL, [shop, entry.id])
        SELECT order_id, kind, currency, amount, presentment_currency, presentment_amount, parent_transaction_id, status
        FROM payment_events WHERE shop = ? AND transaction_id = ?
      SQL
      unless stored
        db.execute(<<~SQL, [shop, entry.id, *facts, entry.status, now, now])
          INSERT INTO payment_events (shop, transaction_id, order_id, kind, currency, amount, presentment_currency,
                                      presentment_amount, parent_transaction_id, status, first_seen_at, updated_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        SQL
        return
      end
      raise Error, "Previously seen transaction details conflict" unless stored.first(7) == facts

      stored_status = stored.last
      return if stored_status == entry.status
      # A fetch that started before an earlier commit can report an older, open status.
      return if FINAL_STATUSES.include?(stored_status) && !FINAL_STATUSES.include?(entry.status)
      raise Error, "Transaction status changed from #{stored_status} to #{entry.status}" if FINAL_STATUSES.include?(stored_status)

      db.execute("UPDATE payment_events SET status = ?, updated_at = ? WHERE shop = ? AND transaction_id = ?",
                 [entry.status, now, shop, entry.id])
    end

    # Facts Shopify allows but an operator should see: open (not yet final)
    # transactions, refunds above what was collected, and captures above their
    # authorization. They are reported, never rejected: Shopify is the source of truth.
    def self.review(db, shop, order_id: nil)
      scope, arguments = order_id ? [" AND order_id = ?", [shop, order_id]] : ["", [shop]]
      open = db.get_first_value(<<~SQL, arguments)
        SELECT COUNT(*) FROM payment_events
        WHERE shop = ? AND status NOT IN (#{FINAL_STATUSES.map { |status| "'#{status}'" }.join(", ")})#{scope}
      SQL
      sides = Hash.new { |hash, key| hash[key] = [BigDecimal("0"), BigDecimal("0")] }
      db.execute("SELECT order_id, currency, kind, amount FROM transactions WHERE shop = ?#{scope}", arguments) do |order, currency, kind, amount|
        sides[[order, currency]][kind == "REFUND" ? 1 : 0] += BigDecimal(amount)
      end
      refunds = sides.select { |_key, (collected, refunded)| refunded > collected }.sort.map do |(order, currency), (collected, refunded)|
        { order_id: order, currency: currency, collected: format_decimal(collected), refunded: format_decimal(refunded) }
      end
      captures = db.execute(<<~SQL, arguments).group_by(&:first).filter_map do |authorization, rows|
        SELECT parent.transaction_id, parent.order_id, parent.currency, parent.amount, capture.amount
        FROM payment_events parent
        JOIN payment_events capture
          ON capture.shop = parent.shop AND capture.parent_transaction_id = parent.transaction_id
         AND capture.kind = 'CAPTURE' AND capture.status = 'SUCCESS'
        WHERE parent.shop = ? AND parent.kind IN ('AUTHORIZATION', 'EMV_AUTHORIZATION')
          AND parent.status = 'SUCCESS'#{scope.sub("order_id", "parent.order_id")}
      SQL
        captured = rows.sum(BigDecimal("0")) { |row| BigDecimal(row.last) }
        authorized = BigDecimal(rows.first[3])
        next unless captured > authorized

        { authorization_id: authorization, order_id: rows.first[1], currency: rows.first[2],
          authorized: format_decimal(authorized), captured: format_decimal(captured) }
      end
      { open_transactions: open, refunds_exceeding_collected: refunds, captures_exceeding_authorization: captures }
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
  end
end
