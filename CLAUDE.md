Write like the developer docs of Heroku or Stripe: plain, direct and task-oriented, in the second person and the active voice, with exact names in code formatting. This applies to reports to me and to everything you write (docs, skills, READMEs, PR descriptions).

# packrat-rails

An OpenTelemetry distribution for Rails: it depends on the upstream OpenTelemetry gems, configures
them for Packrat from environment variables, and adds no instrumentation of its own.

## Rules

- **No monkey patch of another gem, in any case.** No prepend or reopen of Sentry, OpenTelemetry,
  Datadog or Rails classes. The gem calls public API only: `SDK.configure`, `add_span_processor`,
  `add_log_record_processor`, the exporter constructors, an instrumentation's `install`.
- **Nothing the gem does may stop the app's boot.** Every step rescues `StandardError` and
  `LoadError` (a missing gem is a `LoadError`, which is not a `StandardError`) and logs one warning
  that names the step.
- **The ingest key is never printed.** `Packrat.redact` every message that can hold it.
  `test/canary_test.rb` collects every string the gem produces.
- **One decision, after the app's own `after_initialize` blocks.** The Railtie registers it from
  `to_prepare`. Do not replace it with `initializer ..., after: :finisher_hook`: the initializer sort
  then runs the whole Finisher (middleware stack, eager load, `after_initialize`) before
  `config/initializers`, and an app that adds middleware in an initializer fails to boot.
- **The Rack span is `Packrat::RackSpan`**, put in the stack early because the stack is frozen by
  the time the decision is made. For the same reason the Action Pack instrumentation's Railtie is
  marked as loaded and never runs. So is Action View's: its `config.after_initialize` block, loaded
  during the decision, runs twice, and `Otel::Setup#subscribe_action_view` subscribes once instead.
- **Credentials never leave the process.** Both exporters are wrapped by `Otel::Scrubber`, and
  `ErrorSpans` scrubs the message, stack and context, because span events are not scrubbed on export.
- **An app adds to the gem's setup with `ActiveSupport.on_load(:packrat) { |setup| ... }`**, which
  runs after the decision. `Packrat.configure` sets the ingest key and URL and nothing else; it is what
  `bin/rails generate packrat --ingest-key=…` writes to `config/initializers/packrat.rb`, and
  `PACKRAT_INGEST_KEY` wins over it. The key arrives after the Railtie's initializers run, so the
  middleware is placed on `Config#allowed?`, never `enabled?`.
- **Standard variables win.** The gem never writes `ENV`; it passes its values as arguments.
- Service objects: `new(args)`, `call` returns `self`, results on readers.
- Comment only what the code cannot say. Requires at the top of a file, except where a comment says
  why one must wait (the logs SDK; instrumentation gems).

## Checks

- `make check`: rubocop and the unit tests. `test/boot_test.rb` boots one Rails app in a child process; the rest boot none.
- `corpus/generate.sh 8.1` then `bundle exec ruby corpus/boot.rb corpus/generated/rails-8.1`: a
  generated app booted against a listener, with every request decoded and checked.
- `bundle exec ruby corpus/boot.rb <worktree> --existing [--expect=appended] [--ruby=ruby-3.1.6] [NAME=value]`:
  a real app. Use a worktree; `--existing` never writes `.env`, which a worktree links to the main
  checkout's. Lessons go in `corpus/NOTES.md`.
