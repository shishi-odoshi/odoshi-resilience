# frozen_string_literal: true

# Hand-rolled minimal dummy app — just enough Rails to exercise the railtie,
# the notification bridge, boot:check, and the breakers. No `rails new`.
require "rails"
require "action_controller/railtie"
require "odoshi/resilience"

module Dummy
  class Application < Rails::Application
    config.load_defaults Rails::VERSION::STRING.to_f
    config.root = File.expand_path("..", __dir__)
    config.eager_load = false
    config.secret_key_base = "dummy-secret-for-tests"
    config.logger = ActiveSupport::Logger.new(File::NULL)
    config.active_support.deprecation = :silence
    config.hosts.clear if config.respond_to?(:hosts)
  end
end
