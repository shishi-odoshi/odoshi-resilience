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

  # Runs a block with ODOSHI_SOCK / ODOSHI_TOKEN set (or removed when
  # nil), restoring the previous values afterwards.
  def with_supervision_env(sock:, token:)
    old = ENV.to_hash.slice("ODOSHI_SOCK", "ODOSHI_TOKEN")
    sock.nil? ? ENV.delete("ODOSHI_SOCK") : ENV["ODOSHI_SOCK"] = sock
    token.nil? ? ENV.delete("ODOSHI_TOKEN") : ENV["ODOSHI_TOKEN"] = token
    yield
  ensure
    ENV.delete("ODOSHI_SOCK")
    ENV.delete("ODOSHI_TOKEN")
    ENV.update(old)
  end

  # Temporarily override breaker config + registry so a test gets breakers
  # built with its own thresholds, then restores everything.
  def with_breaker_config(overrides)
    cfg = Odoshi::Resilience.config
    previous = cfg.breakers
    cfg.breakers = overrides
    Odoshi::Resilience.reset_breakers!
    yield
  ensure
    cfg.breakers = previous
    Odoshi::Resilience.reset_breakers!
  end

  def with_instrumentation(kind)
    cfg = Odoshi::Resilience.config
    setter = "instrument_#{kind}="
    previous = cfg.public_send("instrument_#{kind}")
    cfg.public_send(setter, true)
    yield
  ensure
    cfg.public_send(setter, previous)
  end
end
