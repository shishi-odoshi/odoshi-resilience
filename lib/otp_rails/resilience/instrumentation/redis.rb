# frozen_string_literal: true

module OtpRails
  module Resilience
    module Instrumentation
      # SOFT integration (DESIGN §7): activates only when the redis-client gem
      # is already loaded (RedisClient is the core of redis-rb >= 5). Never a
      # hard dependency; installing without a client present is a no-op that
      # returns false.
      #
      # Registers a RedisClient middleware wrapping connect / call /
      # call_pipelined in the :redis breaker. Only connection-level errors
      # (RedisClient::ConnectionError) count as failures — command errors
      # (e.g. WRONGTYPE) are application errors, not outages.
      #
      # Note: RedisClient.register applies to clients created AFTER
      # registration, which is why the railtie installs during boot.
      module Redis
        module Middleware
          def connect(redis_config)
            return super unless OtpRails::Resilience.instrument?(:redis)

            OtpRails::Resilience.breaker(:redis).call { super }
          end

          def call(command, redis_config)
            return super unless OtpRails::Resilience.instrument?(:redis)

            OtpRails::Resilience.breaker(:redis).call { super }
          end

          def call_pipelined(commands, redis_config)
            return super unless OtpRails::Resilience.instrument?(:redis)

            OtpRails::Resilience.breaker(:redis).call { super }
          end
        end

        class << self
          def installed? = !!@installed

          def install!
            return false if @installed
            return false unless defined?(::RedisClient) && ::RedisClient.respond_to?(:register)

            ::RedisClient.register(Middleware)
            @installed = true
          end
        end
      end
    end
  end
end
