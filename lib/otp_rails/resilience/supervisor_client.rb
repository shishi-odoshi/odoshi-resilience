# frozen_string_literal: true

require "socket"
require "json"

module OtpRails
  module Resilience
    # The object behind Rails.supervisor inside a supervised child process.
    #
    # restart! speaks the FROZEN otp-rails control protocol (DESIGN §5/§9,
    # otp-rails hard rule 4): one newline-delimited JSON object over the Unix
    # socket the supervisor exported via OTP_RAILS_SOCK, authenticated by the
    # per-boot OTP_RAILS_TOKEN. No extensions, no replies, no versions.
    class SupervisorClient
      # True when this process was spawned under an otp-rails supervisor.
      def supervised?
        !ENV["OTP_RAILS_SOCK"].to_s.empty? && !ENV["OTP_RAILS_TOKEN"].to_s.empty?
      end

      # DESIGN §7: restarting is a feature, not a failure — this is the cheap,
      # public, recommended remediation. Sends exactly:
      #
      #   {"cmd":"restart","id":"jobs","token":"<per-boot token>"}\n
      #
      # Returns true after the line is written. Raises Unsupervised when not
      # running under a supervisor (conservative: a remediation must never
      # silently not happen).
      def restart!(id)
        unless supervised?
          raise Unsupervised,
                "Rails.supervisor.restart!(#{id.inspect}) called, but this process is not " \
                "running under an otp-rails supervisor (OTP_RAILS_SOCK/OTP_RAILS_TOKEN unset). " \
                "Guard with Rails.supervisor.supervised? if this is expected."
        end

        line = JSON.generate({ "cmd" => "restart", "id" => id.to_s, "token" => ENV["OTP_RAILS_TOKEN"] })
        UNIXSocket.open(ENV["OTP_RAILS_SOCK"]) { |sock| sock.write("#{line}\n") }
        true
      end

      # Convenience over the bridged ActiveSupport::Notifications events
      # (DESIGN §6). Yields a hash:
      #
      #   { name: "otp_rails.child.restart",
      #     event: [:otp_rails, :child, :restart],
      #     payload: { id: :jobs, attempt: 1, backoff_ms: 1000, ... } }
      #
      # Returns a subscriber handle for unsubscribe.
      def subscribe(pattern = /\Aotp_rails\./, &block)
        require "active_support/notifications"
        ActiveSupport::Notifications.subscribe(pattern) do |name, *args|
          payload = args.last.is_a?(Hash) ? args.last : {}
          block.call({ name: name, event: name.split(".").map(&:to_sym), payload: payload })
        end
      end

      def unsubscribe(subscriber)
        require "active_support/notifications"
        ActiveSupport::Notifications.unsubscribe(subscriber)
      end

      # Rails.supervisor.breaker(:redis) { redis.get(k) } — see Breaker.
      def breaker(name, **opts, &block)
        Resilience.breaker(name, **opts, &block)
      end
    end
  end
end
