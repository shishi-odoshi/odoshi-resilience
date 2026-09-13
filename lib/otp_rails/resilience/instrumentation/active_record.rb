# frozen_string_literal: true

module OtpRails
  module Resilience
    module Instrumentation
      # Opt-in: wraps ActiveRecord connection checkout in the :active_record
      # breaker. Repeated ActiveRecord::ConnectionTimeoutError (pool
      # exhaustion) opens the circuit, so subsequent callers fail fast with
      # Breaker::OpenError instead of each waiting out checkout_timeout.
      #
      # The prepend happens once; the patch checks the runtime switch on every
      # call, so config.otp_rails_resilience.instrument_active_record can be
      # flipped without unpatching.
      module ActiveRecord
        module PoolPatch
          def checkout(*args, &block)
            return super unless OtpRails::Resilience.instrument?(:active_record)

            OtpRails::Resilience.breaker(:active_record).call { super(*args, &block) }
          end
        end

        class << self
          def installed? = !!@installed

          def install!
            return false if @installed
            return false unless defined?(::ActiveRecord::ConnectionAdapters::ConnectionPool)

            ::ActiveRecord::ConnectionAdapters::ConnectionPool.prepend(PoolPatch)
            @installed = true
          end
        end
      end
    end
  end
end
