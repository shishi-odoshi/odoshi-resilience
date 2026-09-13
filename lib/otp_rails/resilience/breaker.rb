# frozen_string_literal: true

module OtpRails
  module Resilience
    # Minimal circuit breaker (DESIGN §7). Deliberately boring: consecutive
    # failure counting, three states, no sliding windows, no percentiles.
    #
    #   closed    — calls pass through; expected errors count as failures.
    #   open      — calls raise Breaker::OpenError immediately (fail fast).
    #   half_open — after cool_off seconds open, exactly ONE trial call is
    #               admitted at a time (single-flight); concurrent callers get
    #               OpenError until the trial resolves. A trial success closes
    #               the circuit, a trial failure re-opens it. No thundering
    #               herd on a recovering resource.
    #
    # FAIL-OPEN STORAGE (Faulty's rule, DESIGN §7): if the breaker's own
    # bookkeeping raises — the storage backend is broken — the circuit OPENS
    # (raise fast) rather than the app hanging on a resource the breaker can
    # no longer protect. Storage is retried after cool_off, so a healed
    # backend closes things again.
    class Breaker
      class OpenError < Resilience::Error
        attr_reader :breaker_name

        def initialize(breaker_name, message = nil)
          @breaker_name = breaker_name
          super(message || "circuit #{breaker_name} is open")
        end
      end

      # Pragmatic v0.1 defaults for the wired-in breakers (overridable via
      # config.otp_rails_resilience.breakers).
      DEFAULTS_BY_NAME = {
        active_record: { threshold: 3, cool_off: 5.0 },
        http:          { threshold: 5, cool_off: 10.0 },
        redis:         { threshold: 3, cool_off: 5.0 }
      }.freeze

      # Simplest possible storage; the abstraction exists so the fail-open
      # semantics are real (any storage can be swapped in, and any storage
      # failure opens the circuit).
      class MemoryStorage
        def initialize
          @data = {}
          @mutex = Mutex.new
        end

        def get(key)  = @mutex.synchronize { @data[key] }
        def set(key, value) = @mutex.synchronize { @data[key] = value }
      end

      attr_reader :name, :threshold, :cool_off, :expected_errors

      def initialize(name, threshold: 5, cool_off: 10.0, expected_errors: [StandardError], storage: MemoryStorage.new)
        @name = name.to_sym
        @threshold = Integer(threshold)
        @cool_off = Float(cool_off)
        @expected_errors = Array(expected_errors)
        @storage = storage
        @storage_failed_at = nil
        @mutex = Mutex.new
        @trial_mutex = Mutex.new
        @trial_in_flight = false
      end

      # count_success: false makes the call fail-fast/fail-count only — an
      # expected error still counts and an open circuit still raises, but a
      # success does NOT reset the consecutive-failure count. Used when one
      # breaker guards two phases of an operation (e.g. Net::HTTP connect +
      # read) and success of the cheap phase must not erase failures of the
      # real one.
      def call(count_success: true)
        current = state
        raise OpenError, @name if current == :open

        # Single-flight half-open: exactly one caller runs the trial; everyone
        # else fails fast until it resolves.
        trial = current == :half_open
        acquire_trial! if trial

        begin
          result = yield
          record_success if count_success
          result
        rescue Exception => e # rubocop:disable Lint/RescueException — re-raised below
          record_failure(reopen: trial) if expected?(e)
          raise
        ensure
          release_trial! if trial
        end
      end

      # :closed | :open | :half_open. Storage failure => :open (fail-open),
      # retried after cool_off.
      def state
        if @storage_failed_at
          return :open if monotonic_now - @storage_failed_at < @cool_off

          @storage_failed_at = nil # cool_off elapsed; give storage another chance
        end

        data = read_state
        return :open if data.nil? # storage just failed

        opened_at = data[:opened_at]
        if opened_at
          monotonic_now - opened_at < @cool_off ? :open : :half_open
        else
          :closed
        end
      end

      def open?   = state == :open
      def closed? = state == :closed

      def reset!
        write_state(failures: 0, opened_at: nil)
      end

      private

      def acquire_trial!
        acquired = @trial_mutex.synchronize do
          @trial_in_flight ? false : (@trial_in_flight = true)
        end
        return if acquired

        raise OpenError.new(@name, "circuit #{@name} is half-open with a trial call in flight")
      end

      def release_trial!
        @trial_mutex.synchronize { @trial_in_flight = false }
      end

      def expected?(error)
        @expected_errors.any? { |klass| error.is_a?(klass) }
      end

      def record_failure(reopen: false)
        @mutex.synchronize do
          data = read_state
          next if data.nil? # storage broken; already fail-open via @storage_failed_at

          failures = data[:failures] + 1
          opened_at = data[:opened_at]
          opened_at = monotonic_now if reopen || failures >= @threshold
          write_state(failures: failures, opened_at: opened_at)
        end
      end

      def record_success
        @mutex.synchronize { write_state(failures: 0, opened_at: nil) }
      end

      EMPTY = { failures: 0, opened_at: nil }.freeze

      def read_state
        data = @storage.get(@name) || EMPTY
        @storage_failed_at = nil
        data
      rescue StandardError
        @storage_failed_at = monotonic_now
        nil
      end

      def write_state(data)
        @storage.set(@name, data)
        data
      rescue StandardError
        # Fail-open: broken bookkeeping opens the circuit rather than letting
        # calls through unprotected (or hanging).
        @storage_failed_at = monotonic_now
        nil
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
