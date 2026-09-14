# frozen_string_literal: true

require_relative "test_helper"

class RedisInstrumentationTest < Minitest::Test
  def test_soft_integration_noops_without_a_redis_client
    refute defined?(::RedisClient), "test suite must not depend on a redis client gem"
    assert_equal false, Odoshi::Resilience::Instrumentation::Redis.install!
    refute Odoshi::Resilience::Instrumentation::Redis.installed?
  end

  def test_redis_breaker_still_available_via_wrapper_api_without_client
    Odoshi::Resilience.reset_breakers!
    assert_equal :pong, Rails.supervisor.breaker(:redis) { :pong }
    b = Odoshi::Resilience.breaker(:redis)
    assert_equal 3, b.threshold
    assert_includes b.expected_errors, StandardError,
                    "without RedisClient loaded, expected errors fall back to StandardError"
  ensure
    Odoshi::Resilience.reset_breakers!
  end
end
