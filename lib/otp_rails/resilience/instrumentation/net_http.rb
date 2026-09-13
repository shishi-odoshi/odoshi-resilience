# frozen_string_literal: true

module OtpRails
  module Resilience
    module Instrumentation
      # Opt-in: wraps Net::HTTP connect (do_start) and request I/O
      # (transport_request) in a PER-HOST breaker derived from the :http
      # defaults — one bad host must not open the circuit for every host.
      # Connect timeouts (Net::OpenTimeout), read timeouts (Net::ReadTimeout),
      # refusals and resets count as failures; HTTP error responses do not
      # (a 500 is an answer, not an outage).
      #
      # do_start and transport_request are wrapped instead of #start so a
      # block passed to #start (which runs requests inside it) never nests
      # two calls on the same breaker.
      module NetHTTP
        module Patch
          private

          def do_start
            return super unless OtpRails::Resilience.instrument?(:net_http)

            # count_success: false — a successful CONNECT must not reset the
            # consecutive read-timeout count; only a successful request does.
            OtpRails::Resilience.http_breaker(address, port).call(count_success: false) { super }
          end

          def transport_request(req)
            return super unless OtpRails::Resilience.instrument?(:net_http)

            OtpRails::Resilience.http_breaker(address, port).call { super }
          end
        end

        class << self
          def installed? = !!@installed

          def install!
            return false if @installed

            require "net/http"
            ::Net::HTTP.prepend(Patch)
            @installed = true
          end
        end
      end
    end
  end
end
