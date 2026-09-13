# frozen_string_literal: true

require_relative "test_helper"
require "rbconfig"

# Each case boots the dummy app in a real subprocess and runs the actual
# `boot:check` rake task the railtie registers, then re-runs initializers in
# a forked child of THAT process — full end-to-end, no stubs.
class BootCheckTest < Minitest::Test
  include ResilienceTestHelpers

  RUNNER = File.expand_path("support/boot_check_runner.rb", __dir__)

  def run_boot_check(extra_env = {})
    env = { "RAILS_ENV" => "test" }.merge(extra_env)
    out = IO.popen(env, [RbConfig.ruby, RUNNER], err: %i[child out], &:read)
    [out, $?]
  end

  def test_passes_on_an_idempotent_boot
    out, status = run_boot_check
    assert status.success?, "expected pass, got:\n#{out}"
    assert_match(/boot:check PASSED/, out)
    assert_match(/re-ran \d+ initializer file\(s\) in a forked child/, out)
  end

  def test_fails_loudly_when_an_initializer_raises_on_second_run
    out, status = run_boot_check("DUMMY_RAISE_TWICE" => "1")
    refute status.success?, "expected failure, got:\n#{out}"
    assert_match(/FAIL .*zz_boot_check_fixtures\.rb: RuntimeError: initializer already ran once/, out)
    assert_match(/boot:check FAILED/, out)
  end

  def test_fails_loudly_on_class_level_state_drift
    out, status = run_boot_check("DUMMY_NONIDEMPOTENT" => "1")
    refute status.success?, "expected failure, got:\n#{out}"
    # The unguarded subscribe is caught as subscriber-count drift...
    assert_match(/FAIL state drift: notification_subscribers \d+ -> \d+/, out)
    # ...and the unguarded middleware.use via the frozen-stack raise (issue #3:
    # modern Rails freezes the built middleware stack; there is no counted
    # middleware dimension).
    assert_match(/zz_boot_check_fixtures\.rb: FrozenError/, out)
    refute_match(/middleware_operations/, out, "vestigial dimension removed")
    assert_match(/boot:check FAILED/, out)
  end
end
