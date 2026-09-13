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
