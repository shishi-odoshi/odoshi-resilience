# frozen_string_literal: true

module OtpRails
  module Resilience
    # DESIGN §9: telemetry has two halves — the supervisor's own minimal event
    # bus (OtpRails::Telemetry) and this bridge, which re-emits every event
    # published on the IN-PROCESS bus as an ActiveSupport::Notifications event.
    #
    # Names follow the §6 contract joined with dots: [:otp_rails, :child,
    # :restart] => "otp_rails.child.restart". Payload is measurements merged
    # with metadata (metadata wins on a key collision; the §6 contract keeps
    # them disjoint).
    #
    # Note the scope: OtpRails::Telemetry is an in-process bus. Events emitted
    # in the supervisor process do not cross into children — the socket
    # protocol is frozen and carries only heartbeats and control messages.
    # The bridge covers whatever is emitted in THIS process (see
    # docs/OPEN_QUESTIONS.md).
    module TelemetryBridge
      class << self
        def installed? = !@subscription.nil?

        def install!
          return @subscription if @subscription

          require "active_support/notifications"
          @subscription = OtpRails::Telemetry.subscribe do |event|
            name = event[:event].join(".")
            payload = (event[:measurements] || {}).merge(event[:metadata] || {})
            # instrument (not publish): compatible with every AS subscriber
            # style — classic blocks, event objects, monotonic_subscribe.
            # No block, so the event has zero duration.
            ActiveSupport::Notifications.instrument(name, payload)
          end
        end

        def uninstall!
          return unless @subscription

          OtpRails::Telemetry.unsubscribe(@subscription)
          @subscription = nil
        end
      end
    end
  end
end
