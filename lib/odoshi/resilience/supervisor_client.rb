# frozen_string_literal: true

require "socket"
require "json"

module Odoshi
  module Resilience
    # The object behind Rails.supervisor inside a supervised child process.
    #
    # restart! speaks the FROZEN odoshi control protocol (DESIGN §5/§9,
    # odoshi hard rule 4): one newline-delimited JSON object over the Unix
    # socket the supervisor exported via ODOSHI_SOCK, authenticated by the
    # per-boot ODOSHI_TOKEN. No extensions, no replies, no versions.
    class SupervisorClient
      # True when this process was spawned under an odoshi supervisor.
      def supervised?
        !ENV["ODOSHI_SOCK"].to_s.empty? && !ENV["ODOSHI_TOKEN"].to_s.empty?
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
                "running under an odoshi supervisor (ODOSHI_SOCK/ODOSHI_TOKEN unset). " \
                "Guard with Rails.supervisor.supervised? if this is expected."
        end

        line = JSON.generate({ "cmd" => "restart", "id" => id.to_s, "token" => ENV["ODOSHI_TOKEN"] })
        UNIXSocket.open(ENV["ODOSHI_SOCK"]) { |sock| sock.write("#{line}\n") }
        true
      end

      # Convenience over the bridged ActiveSupport::Notifications events
      # (DESIGN §6). Yields a hash:
      #
      #   { name: "odoshi.child.restart",
      #     event: [:odoshi, :child, :restart],
      #     payload: { id: :jobs, attempt: 1, backoff_ms: 1000, ... } }
      #
      # Returns a subscriber handle for unsubscribe.
      def subscribe(pattern = /\Aodoshi\./, &block)
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
