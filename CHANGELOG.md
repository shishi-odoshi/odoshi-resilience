# Changelog

## Unreleased (0.1.0.dev)

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
