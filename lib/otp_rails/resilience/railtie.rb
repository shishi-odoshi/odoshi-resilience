# frozen_string_literal: true

require "rails/railtie"
require "active_support/ordered_options"

module OtpRails
  module Resilience
    # Wires the gem into a Rails app:
    #
    #   config.otp_rails_resilience.enabled                  (true)
    #   config.otp_rails_resilience.bridge_telemetry         (true)
    #   config.otp_rails_resilience.define_rails_supervisor  (true)
    #   config.otp_rails_resilience.instrument_active_record (false, opt-in)
    #   config.otp_rails_resilience.instrument_net_http      (false, opt-in)
    #   config.otp_rails_resilience.instrument_redis         (false, opt-in)
    #   config.otp_rails_resilience.breakers                 ({} — per-name overrides)
    #
    # Runs after load_config_initializers so settings from application.rb,
    # environments/*.rb and config/initializers/*.rb are all honored.
    class Railtie < ::Rails::Railtie
      config.otp_rails_resilience = ActiveSupport::OrderedOptions.new

      initializer "otp_rails_resilience.apply", after: :load_config_initializers do |app|
        cfg = OtpRails::Resilience.config
        app.config.otp_rails_resilience.each do |key, value|
          setter = "#{key}="
          cfg.public_send(setter, value) if cfg.respond_to?(setter)
        end

        next unless cfg.enabled

        TelemetryBridge.install! if cfg.bridge_telemetry
        OtpRails::Resilience.define_rails_supervisor! if cfg.define_rails_supervisor

        if cfg.instrument_active_record
          ActiveSupport.on_load(:active_record) { Instrumentation::ActiveRecord.install! }
        end
        Instrumentation::NetHTTP.install! if cfg.instrument_net_http
        Instrumentation::Redis.install! if cfg.instrument_redis
      end

      rake_tasks do
        load File.expand_path("tasks/boot_check.rake", __dir__)
      end
    end
  end
end
