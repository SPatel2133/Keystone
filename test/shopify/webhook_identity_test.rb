require "minitest/test"
require_relative "../support/shopify_fixture"

class WebhookIdentityTest < Minitest::Test
  include ShopifyFixture

  def test_reused_webhook_id_must_match_the_committed_order_and_topic
    ShopifyFixture.run do |run|
      delivery_id = "delivery-identity"
      run.with_endpoint do
        assert_equal 200, run.deliver(delivery_id)
        assert_equal 200, run.deliver(delivery_id, payload: { id: 101 })
        assert_equal 409, run.deliver(delivery_id, payload: { id: 102 })
        assert_equal 409, run.deliver(delivery_id, topic: "refunds/create")
        assert_equal 200, run.deliver(delivery_id, shop: BETA, payload: { id: 102 })
      end
      assert_equal [[ALPHA, delivery_id, "orders/updated", ORDER, 0],
                    [BETA, delivery_id, "orders/updated", OTHER_ORDER, 0]],
                   run.read("SELECT shop, webhook_id, topic, order_id, processed FROM inbox ORDER BY id")
      assert_empty run.admin.requests
    end
  end
end
