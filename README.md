# packrat-rails

Tests check your code. [Packrat](https://packrat.sh) checks production: it verifies every pull
request after it deploys and tells you which aren't working.

1. **Claude opens a pull request with checks.** Before Claude Code opens a pull request, the
   [Packrat plugin](https://packrat.sh/docs/claude-code-plugin) drafts the checks it should pass in
   production, such as "checkout errors stay under 0.1%", and when to run them.
2. **Packrat verifies it in production.** When the deploy goes live, Packrat runs each check against
   your app's traces and logs. The pull request is marked **Worked**, **Worked in part**,
   **Did not work** or **Not verified**, in the `/packrat` pane in Claude Code and in a comment on the
   pull request.
3. **Claude follows up.** When a pull request doesn't work, Packrat opens an issue. Run
   `/packrat:ask` with its ID, and Claude reads the production data behind it to find the cause and
   open a fix.

This gem sends Packrat that data from a Rails app. It sets up OpenTelemetry to send exceptions,
traces and logs with one key. It requires Rails 7.1 or newer and Ruby 3.1 or newer.

## Install

Run the setup command in your app's repository. It installs the Packrat CLI, and Claude Code adds
the gem and opens a pull request:

```sh
curl -fsSL https://packrat.sh/setup | sh
```

To add the gem by hand, use the ingest key from your Packrat setup page:

```sh
bundle add packrat-rails
bin/rails generate packrat --ingest-key=packrat_ingest_…
bin/rails server
```

The generator creates `config/initializers/packrat.rb` and turns on the
[Packrat plugin for Claude Code](https://packrat.sh/docs/claude-code-plugin) in `.claude/settings.json`.
An ingest key can only send data, so you can commit both files.

To turn the gem off, set `PACKRAT_DISABLED=1`. The app then boots as if the gem were not installed.
The gem is also off while `assets:precompile` runs, so a build that boots your new code is not
recorded as a deploy.

## Privacy

The gem redacts data inside your app's process, before anything is exported: email addresses,
IP addresses, your `filter_parameters` and credentials. Strict privacy sends no log text, query strings
or exception messages. See [Privacy](https://packrat.sh/docs/ruby-on-rails#privacy) for what is sent
at each level and how to redact your own data.

## Documentation

The [Ruby on Rails guide](https://packrat.sh/docs/ruby-on-rails) covers the generator's options,
configuration, privacy, how to see what is sent, and running beside Sentry, Datadog or your own
OpenTelemetry setup.

Released under the MIT License.
