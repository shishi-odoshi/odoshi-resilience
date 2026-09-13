# frozen_string_literal: true

require_relative "test_helper"
require "net/http"
require "socket"

# Breaker around a REAL TCP timeout: a server that accepts and then never
# responds, so Net::HTTP hits a genuine read timeout.
class BreakerTcpTest < Minitest::Test
  include ResilienceTestHelpers

  def setup
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @conns = []
    @accepter = Thread.new do
      loop do
        @conns << @server.accept
      rescue IOError, SystemCallError
        break
      end
    end
  end

  def teardown
    @server.close
    @accepter.join(2)
    @conns.each { |c| c.close rescue nil }
  end

  def silent_http
    http = Net::HTTP.new("127.0.0.1", @port)
    http.open_timeout = 2
    http.read_timeout = 0.3
    http
  end

  def test_breaker_opens_on_real_read_timeouts_then_fails_fast
    b = OtpRails::Resilience::Breaker.new(
      :tcp_test, threshold: 2, cool_off: 60.0,
      expected_errors: [Net::OpenTimeout, Net::ReadTimeout]
    )

    2.times do
      assert_raises(Net::ReadTimeout) do
        b.call { silent_http.start { |h| h.get("/") } }
      end
    end

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert_raises(OtpRails::Resilience::Breaker::OpenError) do
      b.call { silent_http.start { |h| h.get("/") } }
    end
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    assert_operator elapsed, :<, 0.2, "open circuit must fail fast, not wait out the timeout"
  end

  def test_net_http_auto_instrumentation_trips_per_host_breaker
    OtpRails::Resilience::Instrumentation::NetHTTP.install!
    assert OtpRails::Resilience::Instrumentation::NetHTTP.installed?

    with_breaker_config(http: { threshold: 2, cool_off: 60 }) do
      with_instrumentation(:net_http) do
        2.times do
          assert_raises(Net::ReadTimeout) { silent_http.start { |h| h.get("/") } }
        end

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        assert_raises(OtpRails::Resilience::Breaker::OpenError) do
          silent_http.start { |h| h.get("/") }
        end
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        assert_operator elapsed, :<, 0.2

        # Different port => different breaker => circuit still closed there.
        other = TCPServer.new("127.0.0.1", 0)
        begin
          per_host = OtpRails::Resilience.http_breaker("127.0.0.1", @port)
          other_breaker = OtpRails::Resilience.http_breaker("127.0.0.1", other.addr[1])
          assert_equal :open, per_host.state
          assert_equal :closed, other_breaker.state
        ensure
          other.close
        end
      end
    end
  end

  def test_instrumentation_disabled_by_default_leaves_net_http_alone
    OtpRails::Resilience::Instrumentation::NetHTTP.install!
    refute OtpRails::Resilience.instrument?(:net_http)
    assert_raises(Net::ReadTimeout) { silent_http.start { |h| h.get("/") } }
  end
end
