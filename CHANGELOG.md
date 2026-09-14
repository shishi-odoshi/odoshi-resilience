# Changelog

## Unreleased (0.1.0.dev)

Renamed with the ecosystem: **otp-rails-resilience is now odoshi-resilience**
(otp-rails itself became odoshi 0.3.0):

- Gem `otp-rails-resilience` -> `odoshi-resilience`; module
  `OtpRails::Resilience` -> `Odoshi::Resilience`; require path
  `otp_rails/resilience` -> `odoshi/resilience`.
- Depends on `odoshi ~> 0.3` (was `otp-rails`): module `Odoshi`, env vars
  `ODOSHI_SOCK`/`ODOSHI_TOKEN` (was `OTP_RAILS_SOCK`/`OTP_RAILS_TOKEN`),
  telemetry events `[:odoshi, ...]`.
- Bridged ActiveSupport::Notifications names are now `odoshi.child.restart`
  style (was `otp_rails.child.restart`); railtie config namespace is
  `config.odoshi_resilience` (was `config.otp_rails_resilience`).
- The `Rails.supervisor` API is unchanged (Rails-side naming, unaffected).
- Never published under the old name; no compatibility shims. Entries below
  this point keep their original naming for historical accuracy.

Adversarial QA fixes (#1, #2, #3):

- Telemetry bridge isolates raising ActiveSupport::Notifications subscribers:
  the instrument call is rescued so app-subscriber bugs can no longer
  propagate into `OtpRails::Telemetry.emit` or starve other bus subscribers;
  rescued errors surface via `TelemetryBridge.on_error` (default Rails.logger).
- Breaker half-open is now single-flight: exactly one caller runs the trial,
  concurrent callers get `OpenError` until it resolves (no thundering herd on
  a recovering resource).
- boot:check: removed the vestigial "middleware operations" drift dimension
  (always 0/0 on modern Rails; unguarded `middleware.use` is caught by the
  frozen-stack `FrozenError` on the second run) and documented that accurately.
- README: runbook note that `restart!` must be called from inside the
  supervision tree (reference pattern: route through a controller in the web
  child).

- Railtie bridging `OtpRails::Telemetry` events into `ActiveSupport::Notifications`
  (`otp_rails.*` names per DESIGN §6), with `Rails.supervisor.subscribe` on top.
- `Rails.supervisor.restart!(:id)` — one NDJSON control line over the supervision
  socket (frozen wire protocol). Raises `OtpRails::Resilience::Unsupervised` when
  not running under a supervisor.
- Minimal circuit breaker with fail-open storage semantics; registry with
  pragmatic defaults for `:active_record`, `:http`, `:redis`; opt-in
  auto-instrumentation for ActiveRecord pool checkout, Net::HTTP connect/read,
  and RedisClient (soft — only when a client is present).
- `bin/rails boot:check` — re-runs `config/initializers/*.rb` in a forked child
  and fails loudly on a raise or tracked class-level state drift.
