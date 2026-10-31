# packrat-rails

**To turn it off, set `PACKRAT_DISABLED=1`.** The app then boots as if the gem were not installed.

OpenTelemetry for Rails, configured to send traces, logs and exceptions to
[Packrat](https://packrat.sh) with one key.

```sh
bundle add packrat-rails
bin/rails generate packrat --ingest-key=packrat_ingest_…
bin/rails server
```

The generator creates `config/initializers/packrat.rb` with the ingest key from your Packrat setup
page:

```ruby
Packrat.configure do |config|
  config.ingest_key = ENV.fetch("PACKRAT_INGEST_KEY", "packrat_ingest_…")
  # :strict sends no log text, query strings or exception messages: https://packrat.sh/docs/ruby-on-rails#privacy
  # config.privacy = :strict
end
```

An ingest key can only send data, so you can commit the file. To keep the key out of the repository,
run the generator without `--ingest-key` and set `PACKRAT_INGEST_KEY` where the app runs.

The generator also turns on the [Packrat plugin for Claude Code](https://packrat.sh/docs/claude-code-plugin)
in `.claude/settings.json`. Commit the file, and everyone who opens Claude Code in the repository and
trusts the folder gets the plugin. If the file exists, the generator adds the plugin and keeps the rest.
To leave the file alone, pass `--no-claude-code`.

To start with [strict privacy](#privacy), pass `--strict`.

On boot the gem writes one line to the Rails log. It names the service and environment the app
reports under:

```
Packrat: sending traces and logs for shop/production to https://ingest.packrat.sh (rack, action_pack, active_job, active_record, net_http, pg, logger); redacting email and ip
```

## Configuration

The ingest key, the ingest URL and the privacy level are the only settings in `Packrat.configure`. Everything else is
an environment variable.

| Variable                        | Default                     | Note                                                         |
| ------------------------------- | --------------------------- | ------------------------------------------------------------ |
| `PACKRAT_INGEST_KEY`            | `config.ingest_key`         | Wins over the initializer. With neither, the gem sends nothing and says so |
| `PACKRAT_INGEST_URL`            | `config.ingest_url`, else `https://ingest.packrat.sh` | A local Packrat is `http://localhost:3100`. `--ingest-url` on the generator writes `config.ingest_url` |
| `PACKRAT_DISABLED`              | unset                       | `1` turns the gem off in any environment                     |
| `PACKRAT_OTEL_INSTRUMENTATIONS` | the list below              | Comma-separated names to add; a leading `-` removes one      |
| `PACKRAT_PRIVACY`               | `config.privacy`, else `standard` | `standard` or `strict`. Wins over the initializer. Any other value is strict |
| `PACKRAT_REDACT`                | `email,ip`                  | Patterns redacted from values; `-ip` stops masking IP addresses |

The instrumentations are `rack`, `action_pack`, `action_view`, `active_job`, `active_record`,
`net_http`, `pg`, `mysql2`, `sidekiq`, `redis`, `aws_sdk`, `concurrent_ruby`, `rake` and `logger`. One for a library that is not in the app installs nothing.
`PACKRAT_OTEL_INSTRUMENTATIONS=faraday,-action_view` adds Faraday (with
`opentelemetry-instrumentation-faraday` in the Gemfile) and removes Action View. `action_mailer` and
`active_storage` cannot be added: they must load before boot ends.

The service name is `OTEL_SERVICE_NAME`, else `service.name` in `OTEL_RESOURCE_ATTRIBUTES`, else the
app's module name (`Shop::Application` is `shop`). The environment is `Rails.env` unless
`OTEL_RESOURCE_ATTRIBUTES` names one. The version is `BUILD_COMMIT`, `HEROKU_SLUG_COMMIT` or
`SOURCE_VERSION`. The instance is `DYNO`, else the host name. A standard `OTEL_*` variable that is set always wins.

The gem does nothing in the test environment.

## Privacy

The gem removes data inside your app's process, before anything is exported, so nothing it removes
reaches Packrat. There are two levels: `standard`, the default, and `strict`.

| Data                             | Standard                                                 | Strict                                   |
| -------------------------------- | -------------------------------------------------------- | ---------------------------------------- |
| Request path, route and status   | Sent                                                     | Sent                                     |
| Query string                     | Sent, with filtered parameters replaced                  | Not sent                                 |
| Request and response headers     | Not sent                                                 | Not sent                                 |
| User agent                       | Sent                                                     | Not sent                                 |
| SQL and Redis commands           | Sent with every value replaced by `?`                    | Sent with every value replaced by `?`    |
| Log lines                        | Sent, redacted                                           | Severity and request only; text is `[REDACTED]` |
| Exception class and stack frames | Sent                                                     | Sent                                     |
| Exception message                | Sent, redacted                                           | `[REDACTED]`, in the stack as well       |
| `Rails.error` context            | Sent, redacted                                           | Not sent                                 |
| Job arguments                    | Not sent                                                 | Not sent                                 |
| Client IP address                | Not recorded on spans; masked in log lines               | Not sent                                 |

In standard, the gem redacts:

- **Email addresses**, which become `[email:4f2a91c0]`: the first eight hex digits of an HMAC-SHA256
  keyed by the ingest key. The same address gives the same token, so you can still count per person.
- **IP addresses**, which keep their network: `203.0.113.77` becomes `203.0.113.0`, and IPv6 its
  `/48`. The addresses of servers the app calls (`net.peer.ip`, `server.address`) are kept.
- **Parameters in `filter_parameters`**, in query strings and in `Rails.error` context: the same list
  Rails filters your logs with.
- **Credentials**: values named like a key, token, password, secret, signature or credential, and
  `Bearer` or `Basic` values.

Patterns can't recognize other personal data, such as a name or a support ticket's text in a log
line. If your logs can hold that, use strict: pass `--strict` to the generator, set
`config.privacy = :strict`, or set `PACKRAT_PRIVACY=strict`. Strict keeps routes, durations, status
codes, errors by class and the shape of each query, which is what a deploy check needs.

## Beside other tools

- **Nothing else:** the gem configures OpenTelemetry.
- **Your own OpenTelemetry setup:** the gem leaves it as it is and adds a second exporter, to Packrat.
  If your exporter already sends to Packrat, it adds nothing.
- **Sentry:** both run. The gem does not touch Sentry.
- **Datadog's tracer:** the gem does nothing. Dual-ship from the Datadog Agent instead:
  https://packrat.sh/docs/datadog
