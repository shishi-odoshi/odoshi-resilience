# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

ENV["RAILS_ENV"] = "test"
require_relative "dummy/config/environment"
require "minitest/autorun"
require "fileutils"

module ResilienceTestHelpers
  SCRATCH = File.expand_path("../tmp/test", __dir__)

  def scratch_dir
    FileUtils.mkdir_p(SCRATCH)
    SCRATCH
  end

  # Runs a block with OTP_RAILS_SOCK / OTP_RAILS_TOKEN set (or removed when
  # nil), restoring the previous values afterwards.
  def with_supervision_env(sock:, token:)
    old = ENV.to_hash.slice("OTP_RAILS_SOCK", "OTP_RAILS_TOKEN")
    sock.nil? ? ENV.delete("OTP_RAILS_SOCK") : ENV["OTP_RAILS_SOCK"] = sock
    token.nil? ? ENV.delete("OTP_RAILS_TOKEN") : ENV["OTP_RAILS_TOKEN"] = token
    yield
  ensure
    ENV.delete("OTP_RAILS_SOCK")
    ENV.delete("OTP_RAILS_TOKEN")
    ENV.update(old)
  end

  # Temporarily override breaker config + registry so a test gets breakers
  # built with its own thresholds, then restores everything.
  def with_breaker_config(overrides)
    cfg = OtpRails::Resilience.config
    previous = cfg.breakers
    cfg.breakers = overrides
    OtpRails::Resilience.reset_breakers!
    yield
  ensure
    cfg.breakers = previous
    OtpRails::Resilience.reset_breakers!
  end

  def with_instrumentation(kind)
    cfg = OtpRails::Resilience.config
    setter = "instrument_#{kind}="
    previous = cfg.public_send("instrument_#{kind}")
    cfg.public_send(setter, true)
    yield
  ensure
    cfg.public_send(setter, previous)
  end
end
