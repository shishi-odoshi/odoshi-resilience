# frozen_string_literal: true

require "json"

module Odoshi
  module Resilience
    # bin/rails boot:check — DESIGN §7: "boot must be idempotent".
    #
    # Pragmatic v0.1 reading: after the app has booted once (the rake task
    # depends on :environment), fork a child and, inside it, load every file
    # under config/initializers a SECOND time. The check fails loudly when
    #
    #   1. any initializer file raises on the second run, or
    #   2. tracked class-level state changed between the runs:
    #        - ActiveSupport::Notifications subscriber count (an unguarded
    #          subscribe doubles on re-run — the classic double-boot bug)
    #
    # Unguarded `config.middleware.use` is caught by path 1 on modern Rails:
    # the middleware stack is frozen once built, so the re-run raises
    # FrozenError. (A counted middleware dimension existed in early 0.1 but
    # always read 0/0 post-boot — vestigial, removed; see issue #3.)
    #
    # Scope (documented in the README): only the application's own
    # config/initializers/*.rb are re-run — not the framework/railtie
    # initializer chain, which is not designed to be re-entrant and would
    # false-fail on stock Rails. State tracking is a fingerprint, not a full
    # heap diff; see the README for what this does and does not catch.
    # Everything happens in a fork, so the parent process is never polluted.
    module BootCheck
      class << self
        # Returns true when the check passed. Writes a report to io.
        def run(app, io: $stdout)
          unless Process.respond_to?(:fork)
            io.puts "boot:check SKIPPED: Process.fork is unavailable on this platform"
            return true
          end

          reader, writer = IO.pipe
          pid = fork do
            reader.close
            result = check_in_child(app)
            writer.write(JSON.generate(result))
            writer.close
            exit!(result[:ok] ? 0 : 1) # exit! — skip at_exit hooks inherited from the app
          end
          writer.close
          raw = reader.read
          reader.close
          _, status = Process.wait2(pid)

          result = begin
            JSON.parse(raw)
          rescue JSON::ParserError
            nil
          end

          if result.nil?
            io.puts "boot:check FAILED: forked child died without reporting (status #{status.exitstatus.inspect})"
            return false
          end

          report(result, io)
          result["ok"] && status.success?
        end

        # -- child side ------------------------------------------------------

        def check_in_child(app)
          files = initializer_files(app)
          before = fingerprint(app)
          errors = []

          files.each do |file|
            load file
          rescue Exception => e # rubocop:disable Lint/RescueException — report, don't die
            errors << { file: file, error: "#{e.class}: #{e.message}" }
          end

          after = fingerprint(app)
          drift = diff(before, after)

          { ok: errors.empty? && drift.empty?,
            files: files.size, errors: errors, drift: drift,
            tracked: before.keys.select { |k| before[k] } }
        end

        def initializer_files(app)
          # Same source Rails::Engine#load_config_initializers uses: the
          # "config/initializers" path is globbed to **/*.rb.
          app.paths["config/initializers"].existent.sort
        end

        # Tracked dimensions. Each returns nil (=> skipped, reported as
        # untracked) when the internals it reads are not available in this
        # Rails version.
        def fingerprint(_app)
          {
            "notification_subscribers" => notification_subscriber_count
          }
        end

        def notification_subscriber_count
          notifier = ActiveSupport::Notifications.notifier
          return nil unless notifier.instance_variable_defined?(:@string_subscribers) &&
                            notifier.instance_variable_defined?(:@other_subscribers)

          strings = notifier.instance_variable_get(:@string_subscribers)
          others = notifier.instance_variable_get(:@other_subscribers)
          strings.values.sum(&:size) + others.size
        rescue StandardError
          nil
        end

        def diff(before, after)
          before.keys.filter_map do |key|
            next if before[key].nil? || after[key].nil? # dimension untracked here
            next if before[key] == after[key]

            { dimension: key, before: before[key], after: after[key] }
          end
        end

        # -- parent side -----------------------------------------------------

        def report(result, io)
          io.puts "boot:check re-ran #{result['files']} initializer file(s) in a forked child " \
                  "(tracked: #{Array(result['tracked']).join(', ')})"

          Array(result["errors"]).each do |err|
            io.puts "  FAIL #{err['file']}: #{err['error']} (raised on second run)"
          end
          Array(result["drift"]).each do |d|
            io.puts "  FAIL state drift: #{d['dimension']} #{d['before']} -> #{d['after']} " \
                    "(an initializer wrote class-level state non-idempotently)"
          end

          if result["ok"]
            io.puts "boot:check PASSED: no initializer raised, no tracked state drift"
          else
            io.puts "boot:check FAILED: boot is not idempotent (DESIGN section 7) — see above"
          end
        end
      end
    end
  end
end
