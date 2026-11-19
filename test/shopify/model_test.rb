require "minitest/autorun"
require_relative "../../lib/event_consumer/bundle"
require_relative "../support/shopify_fuzz"

class ShopifyModelTest < Minitest::Test
  def assert_clean(report)
    assert_empty report["failures"], JSON.pretty_generate(report["failures"])
  end

  def test_fixed_seeds_keep_every_invariant_in_process
    report = ShopifyFuzz.campaign(seed: 20_261_119, runs: 25, steps: 200)
    assert_clean(report)
    assert_operator report["operations"].fetch("crash_before_commit"), :>, 0
    assert_operator report["operations"].fetch("reconcile_failing_page"), :>, 0
  end

  def test_fixed_seeds_keep_every_invariant_with_real_killed_and_concurrent_workers
    report = ShopifyFuzz.campaign(seed: 7, runs: 3, steps: 60, processes: true)
    assert_clean(report)
    assert_operator report["operations"].fetch("kill_mid_fetch"), :>, 0
  end

  def test_oracle_catches_a_planted_wrong_amount_and_shrinks_it
    ops = ShopifyFuzz.generate(42, 40)
    ops.insert(1, { "op" => "mutate", "a" => 0, "b" => 1, "c" => 3 }, { "op" => "worker", "a" => 0, "b" => 0, "c" => 0 })
    ops << { "op" => "plant_wrong_amount", "a" => 0, "b" => 0, "c" => 0 }
    failure = ShopifyFuzz.execute(ops)
    assert_match(/plant_wrong_amount: stored .* is not in the ground truth/, failure.fetch("message"))
    minimal = ShopifyFuzz.shrink(ops)
    assert_operator minimal.size, :<, ops.size
    assert_equal "plant_wrong_amount", minimal.last.fetch("op")
    refute_nil ShopifyFuzz.execute(minimal)
  end
end
