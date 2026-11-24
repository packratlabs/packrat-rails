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
traces and logs, and adds a script to your pages that sends browser events, all with one key. It requires Rails 7.1 or newer and Ruby 3.1 or newer.

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

## Browser events

The gem adds a script to every HTML page your app renders. The script sends browser events to
Packrat: page views, clicks, JavaScript errors, the requests the page makes, and Web Vitals. Packrat
uses them to check a pull request that changes a page against what visitors did on it.

Browser events are on by default and need no setup. The gem serves the script from your app at
`/packrat/browser-<version>.js` and adds a `<script defer>` tag before `</head>`. It leaves alone
responses that are not HTML, downloads, streamed responses and Turbo Frame requests. When your app
has a `Current.user`, the script sends the user's `id`.

To turn browser events off, set `config.browser` in `config/initializers/packrat.rb`:

```ruby
Packrat.configure do |config|
  config.browser = false
end
```

To choose pages by request, pass a lambda. It gets the request and returns `true` to send events:

```ruby
config.browser = ->(request) { !request.path.start_with?("/admin") }
```

A controller can choose for its own actions. Both macros take `only:` and `except:`, and they win
over `config.browser` for the actions they name:

```ruby
class Admin::BaseController < ApplicationController
  skip_packrat_browser
end

class CheckoutsController < ApplicationController
  packrat_browser only: %i[new show]
end
```

To keep an element's text out of click names, add `data-packrat-hide` to it or to a parent. A click
inside it is sent as `(hidden)`. The script also hides clicks inside `data-sentry-block` and
`data-sentry-mask`.

```erb
<div data-packrat-hide><%= @account.api_key %></div>
```

The script redacts query string values in the URLs it sends, using the same parameter names the gem
redacts on the server: credentials, your `filter_parameters` and `config.redact_keys`. With
`config.privacy = :strict`, it sends URLs without their query strings and sends no click names.

If your app sets a content security policy, allow the script to send to the ingest host:

```ruby
Rails.application.config.content_security_policy do |policy|
  policy.connect_src :self, "https://ingest.packrat.sh"
end
```

The script tag carries your policy's nonce when Rails generates one, and it loads from your own host,
so `script-src 'self'` allows it.

## Documentation

The [Ruby on Rails guide](https://packrat.sh/docs/ruby-on-rails) covers the generator's options,
configuration, privacy, how to see what is sent, and running beside Sentry, Datadog or your own
OpenTelemetry setup.

Released under the MIT License. The browser script bundles Datadog's browser SDK under the Apache License 2.0; see `LICENSE-THIRD-PARTY`.
