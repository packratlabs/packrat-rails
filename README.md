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
end
```

An ingest key can only send data, so you can commit the file. To keep the key out of the repository,
run the generator without `--ingest-key` and set `PACKRAT_INGEST_KEY` where the app runs.

On boot the gem writes one line to the Rails log. It names the service and environment the app
reports under:

```
Packrat: sending traces and logs for shop/production to https://ingest.packrat.sh (rack, action_pack, active_job, active_record, net_http, pg, logger)
```

## Configuration

The ingest key and the ingest URL are the only settings in `Packrat.configure`. Everything else is an environment
variable.

| Variable                        | Default                     | Note                                                         |
| ------------------------------- | --------------------------- | ------------------------------------------------------------ |
| `PACKRAT_INGEST_KEY`            | `config.ingest_key`         | Wins over the initializer. With neither, the gem sends nothing and says so |
| `PACKRAT_INGEST_URL`            | `config.ingest_url`, else `https://ingest.packrat.sh` | A local Packrat is `http://localhost:3100`. `--ingest-url` on the generator writes `config.ingest_url` |
| `PACKRAT_DISABLED`              | unset                       | `1` turns the gem off in any environment                     |
| `PACKRAT_OTEL_INSTRUMENTATIONS` | the list below              | Comma-separated names to add; a leading `-` removes one      |

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

## Beside other tools

- **Nothing else:** the gem configures OpenTelemetry.
- **Your own OpenTelemetry setup:** the gem leaves it as it is and adds a second exporter, to Packrat.
  If your exporter already sends to Packrat, it adds nothing.
- **Sentry:** both run. The gem does not touch Sentry.
- **Datadog's tracer:** the gem does nothing. Dual-ship from the Datadog Agent instead:
  https://packrat.sh/docs/datadog
