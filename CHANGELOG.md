# Changelog

## Unreleased (0.1.0.dev)

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
