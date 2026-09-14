# frozen_string_literal: true

require_relative "test_helper"

class RailtieTest < Minitest::Test
  include ResilienceTestHelpers

  def test_config_namespace_exists_on_app
    assert_kind_of ActiveSupport::OrderedOptions, Rails.application.config.odoshi_resilience
  end

  def test_defaults_after_boot
    cfg = Odoshi::Resilience.config
    assert_equal true, cfg.enabled
    assert_equal true, cfg.bridge_telemetry
    assert_equal true, cfg.define_rails_supervisor
    assert_equal false, cfg.instrument_active_record
    assert_equal false, cfg.instrument_net_http
    assert_equal false, cfg.instrument_redis
    assert_equal({}, cfg.breakers)
  end

  def test_breaker_defaults_are_pragmatic_and_boring
    defaults = Odoshi::Resilience::Breaker::DEFAULTS_BY_NAME
    assert_equal({ threshold: 3, cool_off: 5.0 }, defaults[:active_record])
    assert_equal({ threshold: 5, cool_off: 10.0 }, defaults[:http])
    assert_equal({ threshold: 3, cool_off: 5.0 }, defaults[:redis])
  end

  def test_version_is_dev
    assert_equal "0.1.0.dev", Odoshi::Resilience::VERSION
    assert Gem::Version.new(Odoshi::Resilience::VERSION).prerelease?
  end
end
