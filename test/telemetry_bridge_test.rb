# frozen_string_literal: true

require_relative "test_helper"

class TelemetryBridgeTest < Minitest::Test
  include ResilienceTestHelpers

  def test_bridge_installed_by_railtie
    assert OtpRails::Resilience::TelemetryBridge.installed?
  end

  def test_telemetry_events_reemitted_as_as_notifications_with_contract_names
    events = []
    sub = ActiveSupport::Notifications.subscribe("otp_rails.child.restart") do |_name, _s, _f, _id, payload|
      events << payload
    end

    OtpRails::Telemetry.emit(:"child.restart",
                             { backoff_ms: 1200 },
                             { id: :jobs, attempt: 2, strategy: :one_for_one })

    assert_equal 1, events.size
    assert_equal({ backoff_ms: 1200, id: :jobs, attempt: 2, strategy: :one_for_one }, events.first)
  ensure
    ActiveSupport::Notifications.unsubscribe(sub)
  end

  def test_install_is_idempotent
    OtpRails::Resilience::TelemetryBridge.install!
    OtpRails::Resilience::TelemetryBridge.install!

    count = 0
    sub = ActiveSupport::Notifications.subscribe("otp_rails.child.spawn") { |*| count += 1 }
    OtpRails::Telemetry.emit(:"child.spawn", {}, { id: :web })
    assert_equal 1, count, "double install! must not double-bridge"
  ensure
    ActiveSupport::Notifications.unsubscribe(sub)
  end

  # Regression for issue #1: a raising AS subscriber must not propagate back
  # into OtpRails::Telemetry.emit and starve bus subscribers registered after
  # the bridge. This must hold WITHOUT relying on any isolation guard in
  # otp-rails itself (defense in depth on both sides).
  def test_raising_as_subscriber_does_not_break_emit_or_starve_bus_subscribers
    surfaced = []
    OtpRails::Resilience::TelemetryBridge.on_error = ->(error, name) { surfaced << [error.class, name] }

    other_bus_events = []
    bus_sub = OtpRails::Telemetry.subscribe { |e| other_bus_events << e } # registered AFTER the bridge
    as_sub = ActiveSupport::Notifications.subscribe("otp_rails.child.healthy") { |*| raise "boom" }

    event = OtpRails::Telemetry.emit(:"child.healthy", {}, { id: :web }) # must not raise

    assert_equal [:otp_rails, :child, :healthy], event[:event], "emit returns normally"
    assert_equal 1, other_bus_events.count { |e| e[:event] == [:otp_rails, :child, :healthy] },
                 "bus subscribers after the bridge still receive the event"
    assert_equal [[RuntimeError, "otp_rails.child.healthy"]], surfaced,
                 "rescued error is surfaced through on_error, not swallowed silently"

    # And the bridge keeps working for subsequent, non-raising events.
    ok = []
    ok_sub = ActiveSupport::Notifications.subscribe("otp_rails.child.spawn") { |*| ok << 1 }
    OtpRails::Telemetry.emit(:"child.spawn", {}, { id: :web })
    assert_equal 1, ok.size
    ActiveSupport::Notifications.unsubscribe(ok_sub)
  ensure
    OtpRails::Resilience::TelemetryBridge.on_error = nil
    ActiveSupport::Notifications.unsubscribe(as_sub) if as_sub
    OtpRails::Telemetry.unsubscribe(bus_sub) if bus_sub
  end

  def test_default_error_handling_logs_instead_of_raising
    as_sub = ActiveSupport::Notifications.subscribe("otp_rails.child.degraded") { |*| raise "boom" }
    # No on_error hook set: the default path (Rails.logger / warn) must not raise.
    OtpRails::Telemetry.emit(:"child.degraded", {}, { id: :web })
  ensure
    ActiveSupport::Notifications.unsubscribe(as_sub) if as_sub
  end

  def test_rails_supervisor_subscribe_convenience_yields_event_hashes
    seen = []
    handle = Rails.supervisor.subscribe { |event| seen << event }

    OtpRails::Telemetry.emit(:"supervisor.escalate", { restarts: 6 }, { within: 60 })

    escalates = seen.select { |e| e[:name] == "otp_rails.supervisor.escalate" }
    assert_equal 1, escalates.size
    event = escalates.first
    assert_equal [:otp_rails, :supervisor, :escalate], event[:event]
    assert_equal 6, event[:payload][:restarts]
    assert_equal 60, event[:payload][:within]

    Rails.supervisor.unsubscribe(handle)
    OtpRails::Telemetry.emit(:"supervisor.escalate", { restarts: 7 }, { within: 60 })
    assert_equal 1, seen.count { |e| e[:name] == "otp_rails.supervisor.escalate" },
                 "unsubscribed handle must not receive further events"
  end
end
