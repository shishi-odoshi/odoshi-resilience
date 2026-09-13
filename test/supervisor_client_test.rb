# frozen_string_literal: true

require_relative "test_helper"
require "socket"

class SupervisorClientTest < Minitest::Test
  include ResilienceTestHelpers

  def test_rails_supervisor_is_defined_and_memoized
    assert Rails.respond_to?(:supervisor)
    assert_kind_of OtpRails::Resilience::SupervisorClient, Rails.supervisor
    assert_same Rails.supervisor, Rails.supervisor
  end

  def test_restart_sends_exact_ndjson_control_line_over_real_unix_socket
    sock_path = File.join(scratch_dir, "sup-#{Process.pid}.sock")
    File.unlink(sock_path) if File.exist?(sock_path)
    server = UNIXServer.new(sock_path)
    token = "a" * 32

    received = nil
    reader = Thread.new do
      conn = server.accept
      received = conn.gets
      conn.close
    end

    with_supervision_env(sock: sock_path, token: token) do
      assert Rails.supervisor.supervised?
      assert_equal true, Rails.supervisor.restart!(:jobs)
    end

    reader.join(5)
    # The FROZEN wire protocol (DESIGN section 5/9): exactly one NDJSON line.
    assert_equal %({"cmd":"restart","id":"jobs","token":"#{token}"}\n), received
  ensure
    server&.close
    File.unlink(sock_path) if sock_path && File.exist?(sock_path)
  end

  def test_restart_accepts_string_ids
    sock_path = File.join(scratch_dir, "sup-str-#{Process.pid}.sock")
    File.unlink(sock_path) if File.exist?(sock_path)
    server = UNIXServer.new(sock_path)

    received = nil
    reader = Thread.new do
      conn = server.accept
      received = conn.gets
      conn.close
    end

    with_supervision_env(sock: sock_path, token: "tok") do
      Rails.supervisor.restart!("web")
    end
    reader.join(5)
    assert_equal %({"cmd":"restart","id":"web","token":"tok"}\n), received
  ensure
    server&.close
    File.unlink(sock_path) if sock_path && File.exist?(sock_path)
  end

  def test_restart_raises_unsupervised_without_socket_env
    with_supervision_env(sock: nil, token: nil) do
      refute Rails.supervisor.supervised?
      err = assert_raises(OtpRails::Resilience::Unsupervised) { Rails.supervisor.restart!(:jobs) }
      assert_match(/not\s+running under an otp-rails supervisor/, err.message)
      assert_match(/supervised\?/, err.message)
    end
  end

  def test_restart_raises_unsupervised_when_token_missing
    with_supervision_env(sock: "/tmp/nonexistent.sock", token: nil) do
      assert_raises(OtpRails::Resilience::Unsupervised) { Rails.supervisor.restart!(:jobs) }
    end
  end
end
