# otp-rails-resilience

Crash-only conventions for Rails apps supervised by
[otp-rails](https://github.com/shishi-odoshi/otp-rails) — the Rails-side half
of the design's slim-supervisor split (DESIGN §7/§9).

The otp-rails supervisor is a separate process that never loads Rails. This
gem runs **inside each Rails child** and provides the four things the
supervisor deliberately cannot:

1. a railtie that bridges supervisor telemetry into
   `ActiveSupport::Notifications`
2. `Rails.supervisor.restart!(:jobs)` — the cheap, public, recommended
   remediation, over the supervision socket
3. minimal, fail-open circuit breakers with pragmatic defaults for
   ActiveRecord / Net::HTTP / Redis
4. `bin/rails boot:check` — boot idempotency verification

Restarting is a feature, not a failure. Boot must be idempotent because in a
crash-only world every boot is a re-boot.

## Install

```ruby
# Gemfile
gem "otp-rails-resilience", require: "otp_rails/resilience"
```

Requires Ruby >= 3.2 and Rails >= 7.1. Runtime dependencies are exactly
`railties`, `activesupport`, and `otp-rails` — the Redis integration is soft
and activates only when a redis client is already present.

## 1. Telemetry bridge

The supervisor's event bus (`OtpRails::Telemetry`, DESIGN §6) is re-emitted as
`ActiveSupport::Notifications` events. Names are the §6 contract joined with
dots; payload is measurements merged with metadata:

```
otp_rails.supervisor.start / .stop / .escalate
otp_rails.child.spawn / .healthy / .degraded / .exit / .restart / .drain / .kill
```

```ruby
ActiveSupport::Notifications.subscribe("otp_rails.child.restart") do |*, payload|
  StatsD.increment("supervisor.restarts", tags: ["child:#{payload[:id]}"])
end
```

Or the convenience API, which yields one normalized hash:

```ruby
Rails.supervisor.subscribe do |event|
  # { name: "otp_rails.child.restart",
  #   event: [:otp_rails, :child, :restart],
  #   payload: { id: :jobs, attempt: 1, backoff_ms: 1000, strategy: :one_for_one } }
end
```

Scope note: `OtpRails::Telemetry` is an in-process bus, and the socket
protocol between supervisor and children is frozen (heartbeats and control
messages only) — so the bridge covers events emitted in *this* process. For
the supervisor's own event stream, use its JSON-lines exporter. See
`docs/OPEN_QUESTIONS.md` #3.

## 2. `Rails.supervisor.restart!`

```ruby
Rails.supervisor.restart!(:jobs)   # => true
```

Sends exactly one NDJSON line over the Unix socket the supervisor exported via
`OTP_RAILS_SOCK`, authenticated with the per-boot `OTP_RAILS_TOKEN`:

```json
{"cmd":"restart","id":"jobs","token":"<per-boot token>"}
```

That wire protocol is **frozen** (otp-rails hard rule 4) — this gem adds no
extensions. The socket is mode 0600 and the token is per-boot; anything that
can write to it can restart workers, which is the point and the boundary.

When the process is not running under a supervisor, `restart!` **raises
`OtpRails::Resilience::Unsupervised`** rather than silently returning — a
remediation that silently does not happen is worse than a loud error. Guard
call sites that legitimately run both ways:

```ruby
Rails.supervisor.restart!(:jobs) if Rails.supervisor.supervised?
```

## 3. Circuit breakers

A minimal breaker — consecutive-failure counting, three states, no sliding
windows — with **fail-open storage** (DESIGN §7, Faulty's rule): if the
breaker's own bookkeeping ever fails, circuits **open** (raise fast) rather
than the app hanging behind a broken breaker. Storage is retried after
`cool_off`, so a healed backend closes things again.

### Wrapper API

```ruby
Rails.supervisor.breaker(:redis) { redis.get(key) }
Rails.supervisor.breaker(:payments, threshold: 3, cool_off: 15,
                         expected_errors: [Faraday::TimeoutError]) { charge! }
```

An open circuit raises `OtpRails::Resilience::Breaker::OpenError` without
invoking the block. Options apply on first use of a name; after that the
registry memoizes.

### Defaults

| breaker | threshold | cool_off | counts as failure |
|---|---|---|---|
| `:active_record` | 3 | 5s | `ActiveRecord::ConnectionTimeoutError` |
| `:http` (per host:port) | 5 | 10s | `Net::OpenTimeout`, `Net::ReadTimeout`, refusals/resets |
| `:redis` | 3 | 5s | `RedisClient::ConnectionError` (when a client is loaded) |

Override per name:

```ruby
config.otp_rails_resilience.breakers = { http: { threshold: 3, cool_off: 30 } }
```

### Opt-in auto-instrumentation

Off by default; each is a one-line opt-in and can be flipped at runtime
(patches check the switch on every call):

```ruby
config.otp_rails_resilience.instrument_active_record = true # pool checkout timeouts
config.otp_rails_resilience.instrument_net_http      = true # connect + read, per host:port
config.otp_rails_resilience.instrument_redis         = true # soft: only if RedisClient is loaded
```

- **ActiveRecord** — wraps connection checkout; repeated pool-exhaustion
  timeouts open the circuit so later callers fail fast instead of each waiting
  out `checkout_timeout`.
- **Net::HTTP** — wraps connect and request I/O in a per-`host:port` breaker
  (one bad upstream never opens the circuit for the others). HTTP error
  responses do not count — a 500 is an answer, not an outage.
- **Redis** — registers a `RedisClient` middleware (redis-rb >= 5) when the
  client gem is present; otherwise a no-op. Never a hard dependency. Only
  connection-level errors count — command errors like WRONGTYPE are
  application bugs, not outages.

This is v0.1: a working breaker and sane defaults, not a Semian clone. No
bulkheads, no adaptive thresholds, no shared cross-process state.

## 4. `bin/rails boot:check`

DESIGN §7: "boot must be idempotent". The task boots your app once (normal
`:environment`), then **forks a child and loads every
`config/initializers/*.rb` a second time**, and fails loudly when:

1. any initializer raises on the second run, or
2. tracked class-level state changed between runs:
   - `ActiveSupport::Notifications` subscriber count (an unguarded
     `subscribe` doubles on re-run — the classic double-boot bug)
   - middleware stack operation count (an unguarded `middleware.use`)

Everything happens in the fork; the parent process is never polluted. Exit
status is non-zero on failure, so it slots into CI as-is.

**What it does not catch** (v0.1, deliberately conservative):

- non-idempotence in the framework/railtie initializer chain — only your app's
  `config/initializers` are re-run (the framework chain is not re-entrant by
  design; see `docs/OPEN_QUESTIONS.md` #2)
- state outside the two tracked dimensions: memoized globals, constants,
  spawned threads/timers, `at_exit` hooks, file or database writes
- non-idempotence in `application.rb`, environment files, or engine
  initializers
- order-dependence between initializers (files are re-run in the same sorted
  order Rails uses)

A pass means "your initializers ran twice in one process without raising or
duplicating tracked state" — necessary for crash-only boot, not sufficient.
Platforms without `Process.fork` skip the check (reported, exit 0).

## Configuration reference

```ruby
config.otp_rails_resilience.enabled                  = true  # master switch
config.otp_rails_resilience.bridge_telemetry         = true
config.otp_rails_resilience.define_rails_supervisor  = true
config.otp_rails_resilience.instrument_active_record = false
config.otp_rails_resilience.instrument_net_http      = false
config.otp_rails_resilience.instrument_redis         = false
config.otp_rails_resilience.breakers                 = {}    # per-name overrides
```

## Development

```
bundle install
bundle exec rake test
```

Tests are Minitest with no mocking library: a hand-rolled dummy app under
`test/dummy`, a real `UNIXServer` standing in for the supervisor socket, real
TCP read timeouts, and real ActiveRecord pool exhaustion.

## License

MIT
