require_relative "storage"

module ShopifyLedger
  class Inbox
    class IdentityConflict < StandardError; end

    def initialize(storage)
      @storage = storage
    end

    def receive(shop:, webhook_id:, topic:, order_id:, after_commit: nil)
      inserted = false
      @storage.connect do |db|
        notify_insert = -> { after_commit.call if inserted && after_commit }
        Storage.transaction(db, after_commit: notify_insert) do
          db.execute(<<~SQL, [shop, webhook_id, topic, order_id])
            INSERT INTO inbox (shop, webhook_id, topic, order_id) VALUES (?, ?, ?, ?)
            ON CONFLICT (shop, webhook_id) DO NOTHING
          SQL
          inserted = db.changes == 1
          unless inserted
            original = db.get_first_row("SELECT topic, order_id FROM inbox WHERE shop = ? AND webhook_id = ?",
                                        [shop, webhook_id])
            raise IdentityConflict unless original == [topic, order_id]
          end
        end
      end
      inserted
    end
  end
end
