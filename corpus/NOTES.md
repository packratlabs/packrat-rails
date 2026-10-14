# What the corpus taught

Each entry says what was expected before the run, what the run showed, and the rule that changed.

## G0, 2026-10-14

### rails-8.1 (generated)

Expected: configure; traces and logs arrive; the decision runs after `finisher_hook`.

The run showed the plan's `initializer "packrat.otel", after: :finisher_hook` sorted to position 146
of 252, with `finisher_hook` at 145. An `after:` across collections makes the sort run the whole
Finisher chain (middleware stack, eager load, `after_initialize` hooks) as soon as it reaches the
gem's initializer, ahead of 106 other initializers, `load_config_initializers` among them. The
generated app still booted; Packrat did not (below). Changed: the decision is an `after_initialize`
block registered from `to_prepare`, which Rails runs after `config/initializers`.

The plan's fallback, an `after_initialize` block registered from inside another, does not work
either: `ActiveSupport.on_load` runs a block at once when its hook is already running.

Loading the Action Pack instrumentation at the end of boot raised `FrozenError`: its install loads a
Railtie whose `before_initialize` block runs at once and inserts the Rack middleware into the built,
frozen stack. Changed: `Packrat::RackSpan` goes in the stack early and becomes the Rack span once
the decision is made, and the Action Pack Railtie is marked as loaded.

The request span is named `GET /hello` (method and route), not `Rails::WelcomeController#index`:
Action Pack 0.18 follows the stable HTTP conventions.

### packrat (worktree, Ruby 3.3.8, Rails 8.1)

Expected: append when `PACKRAT_SELF_ORG` is set (Telemetry.install in `after_initialize`),
configure when it is not.

First run: `uninitialized constant Middleware::EnvelopeMedia`. The app's module is `Packrat`, so
inside `config/application.rb` the gem's `Packrat::Middleware` hid the app's top-level `Middleware`.
Changed: the class is `Packrat::RackSpan`. Any constant the gem adds under `Packrat` can hide a
top-level constant inside an app whose module is `Packrat`, or that has its own `Packrat` module
(Colorbook does). Keep the gem's names few and specific.

Second run: `FrozenError` from Packrat's own telemetry initializer, with the gem off. That was the
`after: :finisher_hook` sort above.

Configure run: `logs exporter failed (NameError: uninitialized constant ...Common::Utilities)`.
Packrat's lock held `opentelemetry-exporter-otlp-common` 0.2.0, and `bundle add` kept it. The logs
exporter from 0.6 calls `Common::Utilities`, which otlp-common has from 0.3, and declares `~> 0.2`.
A bound in our gemspec cannot fix it: every otlp-common from 0.2.0 but 0.2.1 needs Ruby 3.3, and
Colorbook is 3.1. Changed: the warning names the fix, `bundle update opentelemetry-exporter-otlp-common`.

Then both pass. Append adds one processor after the app's own, installs no instrumentation, and
adds no logs (the app has no logger provider).

### colorbook (worktree, Ruby 3.1.6, Rails 7.2)

Expected: append, because `config/initializers/otel.rb` configures the SDK. In fact Colorbook turns
its OpenTelemetry on only when `OTEL_EXPORTER_OTLP_ENDPOINT` is set, and its `.env` does not set it,
so the gem configures. With the variable set to a dummy endpoint, the gem appends.

Append, first run: `the app's OpenTelemetry exporter already sends to http://127.0.0.1:…`. The check
compared hosts only, and the listener and the dummy endpoint share 127.0.0.1. Changed: host and port.

Append, second run: the boot line said "traces and logs" and no log record arrived. Colorbook sends
its log lines through `Packrat::LogBridge` to a logger provider of its own, and its global provider,
made because the logs SDK is loaded, receives nothing. Changed: append adds logs only when the
Logger instrumentation is installed.

Colorbook's `Rails.error` subscriber is `ErrorReporting::SpanSubscriber`, which the name check
(`*ErrorSpans`) does not see, so the gem added its own and every error was recorded twice. Changed:
Colorbook moved to the gem, and its subscriber became the gem's `ErrorSpans`.

Ruby 3.1 resolves older gems: `opentelemetry-exporter-otlp-logs` 0.4.0 and pre-stable span names
(`HTTP GET`). All checks pass.

### colorbook on the gem (Ruby 3.1.6, Rails 7.2)

Expected: Colorbook's own OpenTelemetry code deleted, and the gem doing its work.

Colorbook scrubbed credentials from spans, log lines and error messages before export. Changed: the
scrubber, both scrubbing exporters and Colorbook's error subscriber (skip rules, context, scrubbed
message and stack) are now the gem's, with their tests.

`action_view`, `action_mailer` and `active_storage` in `PACKRAT_OTEL_INSTRUMENTATIONS` failed:
each installs through the Active Support instrumentation without requiring it. Changed: the gem
requires it first. Action Mailer and Active Storage then failed again: each sets up in an
`after_initialize` block of its own Railtie, which runs at once when loaded during the gem's block,
before the Railtie defines the methods it calls. Changed: the gem refuses both with a warning that
says why.

Colorbook kept every root span; the gem's sampler kept only server and consumer roots, so the
scheduler's Rake runs would have gone. When Rails boots inside a task, the root is `rake.execute`.
Changed: the sampler keeps `rake.invoke` and `rake.execute` roots.
