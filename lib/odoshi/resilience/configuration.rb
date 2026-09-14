# frozen_string_literal: true

module Odoshi
  module Resilience
    # Runtime configuration. In a Rails app set these through the railtie:
    #
    #   config.odoshi_resilience.instrument_net_http = true
    #   config.odoshi_resilience.breakers = { http: { threshold: 3 } }
    #
    # Everything is disable-able; `enabled = false` turns the whole gem off.
    # The instrument_* switches are checked at call time, so flipping them at
    # runtime enables/disables the patches without unpatching.
    class Configuration
      attr_accessor :enabled, :bridge_telemetry, :define_rails_supervisor,
                    :instrument_active_record, :instrument_net_http, :instrument_redis,
                    :breakers

      def initialize
        @enabled = true
        @bridge_telemetry = true
        @define_rails_supervisor = true
        @instrument_active_record = false # opt-in (see README)
        @instrument_net_http = false      # opt-in
        @instrument_redis = false         # opt-in
        @breakers = {}                    # { name => { threshold:, cool_off:, expected_errors: } }
      end
    end
  end
end
