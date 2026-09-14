# frozen_string_literal: true

require_relative "lib/odoshi/resilience/version"

Gem::Specification.new do |s|
  s.name        = "odoshi-resilience"
  s.version     = Odoshi::Resilience::VERSION
  s.summary     = "Crash-only conventions and circuit breakers for odoshi supervised apps"
  s.description = "The Rails-side companion to odoshi: a railtie that bridges supervisor " \
                  "telemetry into ActiveSupport::Notifications, Rails.supervisor.restart! over " \
                  "the supervision socket, fail-open circuit breakers for ActiveRecord / " \
                  "Net::HTTP / Redis, and a bin/rails boot:check idempotency task."
  s.authors     = ["timimsms"]
  s.license     = "MIT"
  s.homepage    = "https://github.com/shishi-odoshi/odoshi-resilience"
  s.metadata    = {
    "homepage_uri"    => s.homepage,
    "source_code_uri" => s.homepage,
    "changelog_uri"   => "#{s.homepage}/blob/main/CHANGELOG.md",
    "bug_tracker_uri" => "#{s.homepage}/issues"
  }
  s.required_ruby_version = ">= 3.2"
  s.files = Dir["lib/**/*.{rb,rake}", "README.md", "CHANGELOG.md", "LICENSE"]

  # Runtime dependencies — deliberately nothing else (DESIGN §7/§9):
  # this gem runs inside the Rails child, so railties/activesupport are allowed;
  # the Redis integration is soft (activates only when a redis client is present).
  s.add_dependency "railties", ">= 7.1"
  s.add_dependency "activesupport", ">= 7.1"
  s.add_dependency "odoshi", "~> 0.3"
end
