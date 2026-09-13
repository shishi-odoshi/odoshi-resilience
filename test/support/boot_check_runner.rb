# frozen_string_literal: true

# Subprocess entry point for boot_check_test.rb: boots the dummy app the way
# a real `bin/rails boot:check` invocation would, loads the railtie's rake
# tasks, and invokes the task.
require "bundler/setup"

$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
ENV["RAILS_ENV"] = "test"

require "rake"
require_relative "../dummy/config/environment"

Rails.application.load_tasks
Rake::Task["boot:check"].invoke
