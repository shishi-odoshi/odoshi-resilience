# frozen_string_literal: true

# Deliberately misbehaving initializers for the boot:check tests, gated behind
# env vars so the default dummy boot stays idempotent.

if ENV["DUMMY_NONIDEMPOTENT"]
  # Classic double-boot bugs: an unguarded subscribe and an unguarded
  # middleware.use both duplicate class-level state when run twice.
  class DummyNoopMiddleware
    def initialize(app)
      @app = app
    end

    def call(env)
      @app.call(env)
    end
  end

  ActiveSupport::Notifications.subscribe("dummy.nonidempotent") { |*| }
  Rails.application.config.middleware.use DummyNoopMiddleware
end

if ENV["DUMMY_RAISE_TWICE"]
  raise "initializer already ran once in this process" if $dummy_raise_twice_ran

  $dummy_raise_twice_ran = true
end
