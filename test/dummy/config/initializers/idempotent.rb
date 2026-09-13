# frozen_string_literal: true

# A well-behaved, idempotent initializer: safe to load any number of times.
DUMMY_BOOTED = true unless defined?(DUMMY_BOOTED)
Rails.application.config.x.dummy_setting = 42
