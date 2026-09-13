# frozen_string_literal: true

require_relative "test_helper"

class BreakerTest < Minitest::Test
  include ResilienceTestHelpers

  Boom = Class.new(StandardError)
  Other = Class.new(StandardError)

  def breaker(**opts)
    defaults = { threshold: 3, cool_off: 60.0, expected_errors: [Boom] }
    OtpRails::Resilience::Breaker.new(:test, **defaults.merge(opts))
  end

  def trip(b, times)
    times.times { assert_raises(Boom) { b.call { raise Boom } } }
  end

  def test_closed_circuit_passes_result_through
    assert_equal 42, breaker.call { 42 }
    assert_predicate breaker, :closed?
  end

  def test_opens_after_threshold_consecutive_expected_failures
    b = breaker
    trip(b, 3)
    assert_equal :open, b.state

    calls = 0
    err = assert_raises(OtpRails::Resilience::Breaker::OpenError) { b.call { calls += 1 } }
    assert_equal 0, calls, "open circuit must not invoke the block"
    assert_equal :test, err.breaker_name
  end

  def test_unexpected_errors_propagate_but_do_not_count
    b = breaker
    5.times { assert_raises(Other) { b.call { raise Other } } }
    assert_equal :closed, b.state
  end

  def test_success_resets_consecutive_failure_count
    b = breaker
    trip(b, 2)
    b.call { :ok }
    trip(b, 2)
    assert_equal :closed, b.state, "failures interleaved with successes never reach threshold"
  end

  def test_half_open_after_cool_off_then_success_closes
    b = breaker(cool_off: 0.2)
    trip(b, 3)
    assert_equal :open, b.state

    sleep 0.35
    assert_equal :half_open, b.state
    assert_equal :ok, b.call { :ok }
    assert_equal :closed, b.state
  end

  def test_half_open_trial_failure_reopens
    b = breaker(cool_off: 0.2)
    trip(b, 3)
    sleep 0.35
    assert_equal :half_open, b.state
    assert_raises(Boom) { b.call { raise Boom } }
    assert_equal :open, b.state
  end

  # Regression for issue #2: half-open is single-flight — exactly one caller
  # runs the trial; concurrent callers fail fast with OpenError until it
  # resolves.
  def test_half_open_admits_exactly_one_concurrent_trial
    b = breaker(cool_off: 0.2)
    trip(b, 3)
    sleep 0.35
    assert_equal :half_open, b.state

    entered = 0
    entered_mutex = Mutex.new
    open_errors = 0
    open_mutex = Mutex.new
    latch = Queue.new

    threads = Array.new(30) do
      Thread.new do
        latch.pop # all threads released together
        begin
          b.call do
            entered_mutex.synchronize { entered += 1 }
            sleep 2.0 # keep the trial in flight while every other thread attempts
            :ok
          end
        rescue OtpRails::Resilience::Breaker::OpenError
          open_mutex.synchronize { open_errors += 1 }
        end
      end
    end

    30.times { latch << true }
    threads.each { |t| t.join(15) }

    assert_equal 1, entered, "exactly one caller runs the half-open trial"
    assert_equal 29, open_errors, "concurrent callers fail fast during the trial"
    assert_equal :closed, b.state, "the successful trial closed the circuit"
    assert_equal :ok, b.call { :ok }
  end

  def test_failed_trial_releases_the_slot_for_the_next_trial_after_cool_off
    b = breaker(cool_off: 0.2)
    trip(b, 3)
    sleep 0.35
    assert_raises(Boom) { b.call { raise Boom } } # trial fails -> re-open
    assert_equal :open, b.state

    sleep 0.35 # cool_off again
    assert_equal :half_open, b.state
    assert_equal :ok, b.call { :ok }, "the slot was released; a new trial is admitted"
    assert_equal :closed, b.state
  end

  def test_unexpected_error_during_trial_still_releases_the_slot
    b = breaker(cool_off: 0.2)
    trip(b, 3)
    sleep 0.35
    assert_raises(Other) { b.call { raise Other } } # unexpected: not counted
    assert_equal :half_open, b.state, "unexpected error neither closes nor re-opens"
    assert_equal :ok, b.call { :ok }, "the slot was released by ensure"
    assert_equal :closed, b.state
  end

  # -- fail-open storage semantics (DESIGN section 7) ------------------------

  class BrokenStorage
    def get(_key) = raise(IOError, "storage backend down")
    def set(_key, _value) = raise(IOError, "storage backend down")
  end

  class WriteBrokenStorage < OtpRails::Resilience::Breaker::MemoryStorage
    def set(_key, _value) = raise(IOError, "storage writes down")
  end

  def test_broken_storage_opens_the_circuit_instead_of_hanging
    b = breaker(storage: BrokenStorage.new)
    assert_equal :open, b.state

    calls = 0
    assert_raises(OtpRails::Resilience::Breaker::OpenError) { b.call { calls += 1 } }
    assert_equal 0, calls
  end

  def test_write_only_storage_failure_also_opens
    b = breaker(storage: WriteBrokenStorage.new)
    # First call: reads fine (closed), block raises, the failure WRITE fails.
    assert_raises(Boom) { b.call { raise Boom } }
    # Fail-open: the broken bookkeeping opens the circuit.
    assert_equal :open, b.state
    assert_raises(OtpRails::Resilience::Breaker::OpenError) { b.call { :never } }
  end

  def test_storage_failure_heals_after_cool_off
    storage = OtpRails::Resilience::Breaker::MemoryStorage.new
    flaky = Object.new
    flaky.define_singleton_method(:broken=) { |v| @broken = v }
    flaky.define_singleton_method(:get) { |k| @broken ? raise(IOError) : storage.get(k) }
    flaky.define_singleton_method(:set) { |k, v| @broken ? raise(IOError) : storage.set(k, v) }

    b = breaker(storage: flaky, cool_off: 0.2)
    flaky.broken = true
    assert_equal :open, b.state

    flaky.broken = false
    sleep 0.35
    assert_equal :closed, b.state, "healed storage closes the circuit after cool_off"
    assert_equal :ok, b.call { :ok }
  end

  # -- registry / wrapper API -------------------------------------------------

  def test_registry_memoizes_and_wrapper_runs_block
    OtpRails::Resilience.reset_breakers!
    a = OtpRails::Resilience.breaker(:reg_test)
    assert_same a, OtpRails::Resilience.breaker(:reg_test)
    assert_equal 7, Rails.supervisor.breaker(:reg_test) { 7 }
  ensure
    OtpRails::Resilience.reset_breakers!
  end

  def test_registry_applies_config_overrides_and_named_defaults
    with_breaker_config(redis: { threshold: 1, cool_off: 60 }) do
      b = OtpRails::Resilience.breaker(:redis)
      assert_equal 1, b.threshold
      assert_equal 60.0, b.cool_off

      http = OtpRails::Resilience.breaker(:http)
      assert_equal 5, http.threshold, "DEFAULTS_BY_NAME applies when unconfigured"

      per_host = OtpRails::Resilience.http_breaker("example.test", 80)
      assert_equal :"http.example.test:80", per_host.name
      assert_equal 5, per_host.threshold, "per-host breakers derive from :http defaults"
    end
  end
end
