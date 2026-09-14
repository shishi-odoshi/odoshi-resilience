# frozen_string_literal: true

require_relative "test_helper"
require "active_record"

# Real behavior: a pool of size 1, held by another thread, so checkout
# genuinely times out — no stubs.
class ActiveRecordInstrumentationTest < Minitest::Test
  include ResilienceTestHelpers

  def setup
    ActiveRecord::Base.establish_connection(
      adapter: "sqlite3", database: ":memory:", pool: 1, checkout_timeout: 0.2
    )
    Odoshi::Resilience::Instrumentation::ActiveRecord.install!
    assert Odoshi::Resilience::Instrumentation::ActiveRecord.installed?
    @pool = ActiveRecord::Base.connection_pool

    @release = Queue.new
    @held = Queue.new
    @holder = Thread.new do
      conn = @pool.checkout
      @held << true
      @release.pop
      @pool.checkin(conn)
    end
    @held.pop # pool is now exhausted
  end

  def teardown
    @release << true
    @holder.join(5)
    ActiveRecord::Base.connection_handler.clear_all_connections!
  end

  def test_checkout_timeouts_trip_breaker_then_fail_fast
    with_breaker_config(active_record: { threshold: 2, cool_off: 60 }) do
      with_instrumentation(:active_record) do
        2.times do
          assert_raises(ActiveRecord::ConnectionTimeoutError) { @pool.checkout }
        end

        breaker = Odoshi::Resilience.breaker(:active_record)
        assert_equal :open, breaker.state
        assert_includes breaker.expected_errors, ActiveRecord::ConnectionTimeoutError

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        assert_raises(Odoshi::Resilience::Breaker::OpenError) { @pool.checkout }
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        assert_operator elapsed, :<, 0.1,
                        "open circuit fails fast instead of waiting out checkout_timeout"
      end
    end
  end

  def test_disabled_flag_leaves_checkout_untouched
    refute Odoshi::Resilience.instrument?(:active_record)
    assert_raises(ActiveRecord::ConnectionTimeoutError) { @pool.checkout }
  end
end
