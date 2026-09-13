# frozen_string_literal: true

# otp-rails-resilience — the Rails-side companion to the slim otp-rails
# supervisor (DESIGN §7 crash-only conventions, §9 slim-supervisor split).
#
# The supervisor process never loads Rails; this gem runs INSIDE each Rails
# child and provides:
#   1. a railtie bridging OtpRails::Telemetry into ActiveSupport::Notifications
#   2. Rails.supervisor.restart!(:jobs) over the supervision socket
#   3. fail-open circuit breakers with pragmatic AR / Net::HTTP / Redis defaults
#   4. bin/rails boot:check — boot idempotency verification
#
# Deliberately requires only otp_rails/telemetry from the otp-rails gem, not
# the whole supervisor — children stay featherweight (same philosophy as
# otp_rails/heartbeat).
require "otp_rails/telemetry"

module OtpRails
  module Resilience
    class Error < StandardError; end

    # Raised by Rails.supervisor.restart! when the process is not running
    # under an otp-rails supervisor (no OTP_RAILS_SOCK / OTP_RAILS_TOKEN).
    # Raising (rather than silently returning false) is the conservative
    # choice: restart! is a remediation the caller depends on, and a silent
    # no-op would hide that the remediation never happened.
    class Unsupervised < Error; end
  end
end

require_relative "resilience/version"
require_relative "resilience/configuration"
require_relative "resilience/breaker"
require_relative "resilience/supervisor_client"
require_relative "resilience/telemetry_bridge"
require_relative "resilience/instrumentation/active_record"
require_relative "resilience/instrumentation/net_http"
require_relative "resilience/instrumentation/redis"
require_relative "resilience/boot_check"

module OtpRails
  module Resilience
    @breakers = {}
    @registry_mutex = Mutex.new

    class << self
      def config
        @config ||= Configuration.new
      end

      def supervisor
        @supervisor ||= SupervisorClient.new
      end

      # Defines Rails.supervisor (idempotent; no-op when Rails is absent).
      def define_rails_supervisor!
        return false unless defined?(::Rails)
        return false if ::Rails.respond_to?(:supervisor)
        ::Rails.define_singleton_method(:supervisor) { OtpRails::Resilience.supervisor }
        true
      end

      # Registry: breaker(:redis) returns the (memoized) breaker;
      # breaker(:redis) { ... } runs the block through it.
      # Options apply only on first creation; per-name defaults come from
      # Breaker::DEFAULTS_BY_NAME merged with config.breakers overrides.
      def breaker(name, **opts, &block)
        name = name.to_sym
        b = @registry_mutex.synchronize { @breakers[name] ||= build_breaker(name, opts) }
        block ? b.call(&block) : b
      end

      # Per-host breaker used by the Net::HTTP instrumentation. One bad host
      # must not open the circuit for every other host.
      def http_breaker(address, port)
        breaker(:"http.#{address}:#{port}", **breaker_options_for(:http))
      end

      def reset_breakers!
        @registry_mutex.synchronize { @breakers.clear }
      end

      def instrument?(kind)
        config.enabled && config.public_send("instrument_#{kind}")
      end

      private

      def build_breaker(name, opts)
        base = name.to_s.start_with?("http.") ? :http : name
        Breaker.new(name, **breaker_options_for(base).merge(opts))
      end

      def breaker_options_for(name)
        defaults = Breaker::DEFAULTS_BY_NAME.fetch(name, {})
        overrides = (config.breakers || {}).fetch(name, {})
        opts = { expected_errors: default_expected_errors(name) }.merge(defaults).merge(overrides)
        opts
      end

      # Resolved lazily so the gem never hard-requires ActiveRecord or a Redis
      # client (soft integration, DESIGN §7).
      def default_expected_errors(name)
        case name
        when :active_record
          defined?(::ActiveRecord::ConnectionTimeoutError) ? [::ActiveRecord::ConnectionTimeoutError] : [StandardError]
        when :http
          errs = [SocketError, SystemCallError, EOFError]
          errs += [Net::OpenTimeout, Net::ReadTimeout] if defined?(Net::OpenTimeout)
          errs
        when :redis
          defined?(::RedisClient::ConnectionError) ? [::RedisClient::ConnectionError] : [StandardError]
        else
          [StandardError]
        end
      end
    end
  end
end

require_relative "resilience/railtie" if defined?(Rails::Railtie)
