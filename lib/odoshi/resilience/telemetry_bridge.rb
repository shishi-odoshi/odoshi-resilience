# frozen_string_literal: true

module Odoshi
  module Resilience
    # DESIGN §9: telemetry has two halves — the supervisor's own minimal event
    # bus (Odoshi::Telemetry) and this bridge, which re-emits every event
    # published on the IN-PROCESS bus as an ActiveSupport::Notifications event.
    #
    # Names follow the §6 contract joined with dots: [:odoshi, :child,
    # :restart] => "odoshi.child.restart". Payload is measurements merged
    # with metadata (metadata wins on a key collision; the §6 contract keeps
    # them disjoint).
    #
    # ISOLATION: ActiveSupport::Notifications.instrument re-raises exceptions
    # thrown by app-side AS subscribers. The bridge must never let a buggy app
    # subscriber propagate back into Odoshi::Telemetry.emit and starve the
    # bus subscribers registered after it — so the instrument call is rescued
    # here, independent of any guard the bus itself grows (defense in depth).
    # Rescued errors are surfaced through on_error (default: Rails.logger,
    # else Kernel#warn), never re-raised and never silently dropped.
    #
    # Note the scope: Odoshi::Telemetry is an in-process bus. Events emitted
    # in the supervisor process do not cross into children — the socket
    # protocol is frozen and carries only heartbeats and control messages.
    # The bridge covers whatever is emitted in THIS process (see
    # docs/OPEN_QUESTIONS.md).
    module TelemetryBridge
      class << self
        # Hook called with (error, event_name) when an AS subscriber raises
        # through the bridge. Assign a callable to route rescued errors to
        # your error tracker; nil restores the default (log and continue).
        attr_accessor :on_error

        def installed? = !@subscription.nil?

        def install!
          return @subscription if @subscription

          require "active_support/notifications"
          @subscription = Odoshi::Telemetry.subscribe do |event|
            name = event[:event].join(".")
            payload = (event[:measurements] || {}).merge(event[:metadata] || {})
            begin
              # instrument (not publish): compatible with every AS subscriber
              # style — classic blocks, event objects, monotonic_subscribe.
              # No block, so the event has zero duration.
              ActiveSupport::Notifications.instrument(name, payload)
            rescue StandardError => e
              # A raising app subscriber must not break the telemetry bus.
              handle_error(e, name)
            end
          end
        end

        def uninstall!
          return unless @subscription

          Odoshi::Telemetry.unsubscribe(@subscription)
          @subscription = nil
        end

        private

        def handle_error(error, event_name)
          if on_error
            on_error.call(error, event_name)
          else
            message = "[odoshi-resilience] ActiveSupport::Notifications subscriber raised " \
                      "for #{event_name}: #{error.class}: #{error.message}"
            if defined?(::Rails) && ::Rails.respond_to?(:logger) && ::Rails.logger
              ::Rails.logger.error(message)
            else
              warn(message)
            end
          end
        rescue StandardError
          nil # error reporting must never raise back into the bus either
        end
      end
    end
  end
end
