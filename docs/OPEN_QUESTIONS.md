# Open questions

Genuine design forks hit while building 0.1. Each records the options, the
conservative pick that shipped, and what would change the answer. None blocks
0.1.

## 1. `restart!` when unsupervised: raise vs. no-op false

- (a) **Raise `OtpRails::Resilience::Unsupervised` (shipped).** restart! is a
  remediation runbooks depend on (DESIGN §7); a remediation that silently does
  not happen is worse than a loud error. Callers that legitimately run both
  supervised and unsupervised guard with `Rails.supervisor.supervised?`.
- (b) Return `false` — symmetric with `OtpRails::Heartbeat`, which no-ops when
  unsupervised. Rejected: heartbeats are passive telemetry, restart! is an
  action; the failure modes are not symmetric.

Revisit only if real apps end up wrapping every call site in `supervised?`.

## 2. boot:check scope: app initializers only, not the railtie chain

- (a) **Re-run only `config/initializers/*.rb` (shipped).** §7 targets state
  the app writes during boot; the framework/railtie initializer chain is not
  designed to be re-entrant and re-running it false-fails on stock Rails,
  which would train people to ignore the task.
- (b) Re-run `Rails.application.initializers` in full — stricter, but fails on
  a bare `rails new` app, so the signal drowns.
- (c) Boot the whole environment twice in two subprocesses and diff — closest
  to "crash-only boots twice", but there is nothing cheap and general to diff
  between two separate processes in v0.1.

Revisit (c) when the template repo grows a chaos task that can assert on
boot-twice behavior end to end.

## 3. Telemetry bridge is in-process only

`OtpRails::Telemetry` is an in-process bus; supervisor-process events do not
cross into children. The frozen socket protocol carries only heartbeats and
control messages (otp-rails hard rule 4), so the bridge re-emits whatever is
emitted in the child's own process. Forwarding supervisor events to children
would require a contract extension (a DESIGN §5/§6 edit) — explicitly not done
here. If child-side visibility of supervisor events is wanted, the supported
path today is the supervisor's JSON-lines exporter consumed out-of-band.

## 4. Net::HTTP breaker granularity: per host:port

- (a) **Per `host:port` breakers derived from the `:http` defaults (shipped).**
  One flaky host must not open the circuit for every outbound call.
- (b) One global `:http` breaker — simpler, but wrong in any app with more
  than one upstream.

Unbounded cardinality (one breaker per host ever contacted) is accepted for
v0.1; apps talking to thousands of dynamic hosts should keep instrumentation
off and use the wrapper API.

## 5. boot:check state fingerprint reads AS::Notifications internals

Subscriber counting reads `Fanout` ivars (`@string_subscribers` /
`@other_subscribers`) because ActiveSupport exposes no public subscriber
enumeration. It is guarded: when the ivars disappear in a future Rails, the
dimension is skipped (reported as untracked) instead of crashing, and the
raise-on-second-run check still stands. A public API request upstream would be
the clean fix. (The middleware-operations dimension originally listed here as
backup was vestigial on Rails 8.1 — always 0/0 post-boot, with FrozenError
doing the real catching — and was removed in issue #3.)
