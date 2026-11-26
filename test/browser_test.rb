require "test_helper"
require "action_dispatch"
require "cgi"

class BrowserTest < PackratTest
  PAGE = "<!doctype html><html><head><title>Shop</title></head><body>café</body></html>".freeze
  SCRIPT = "/packrat/browser-#{Packrat::VERSION}.js".freeze

  class Body
    attr_reader :closed

    def initialize(*parts)
      @parts = parts
    end

    def each(&) = @parts.each(&)
    def to_ary = @parts
    def close = @closed = true
  end

  class PagesController
    include Packrat::Browser::Controller
    attr_reader :action_name

    def initialize(action_name)
      @action_name = action_name
    end
  end

  def test_serves_the_script_with_long_cache_headers
    status, headers, body = middleware.call(env(SCRIPT))

    assert_equal 200, status
    assert_equal "text/javascript", headers["content-type"]
    assert_equal "public, max-age=31536000, immutable", headers["cache-control"]
    assert_equal File.binread(Packrat::Browser::FILE), body.join
    assert_equal body.join.bytesize.to_s, headers["content-length"]
  end

  def test_adds_the_script_before_head_and_fixes_the_length
    body = Body.new(PAGE)
    status, headers, page = middleware(body:).call(env)
    html = page.join

    assert_equal 200, status
    assert body.closed
    assert_match %r{<script defer src="#{SCRIPT}" data-config="[^"]+"></script></head>}, html
    assert_equal 1, html.scan("<script").size
    assert_equal html.bytesize.to_s, headers["content-length"]
    assert_equal Encoding::UTF_8, html.encoding
    assert html.valid_encoding?
  end

  def test_the_config_names_the_intake_the_versions_and_the_privacy
    settings = data_config(middleware(setup: run_setup(config({ "BUILD_COMMIT" => "abc123" }), filters: [ :passw, /ssn/ ])))

    assert_equal "#{URL}/rum/shop/production/#{CANARY}", settings["intake"]
    assert_equal "shop", settings["service"]
    assert_equal "production", settings["env"]
    assert_equal "abc123", settings["version"]
    assert_equal "packrat-rails/#{Packrat::VERSION}", settings["packrat"]
    assert_equal false, settings["strict"]
    assert_nil settings["user"]
    assert_equal Packrat::Otel::Scrubber::CREDENTIAL_SEGMENTS, settings.dig("redact", "segments")
    assert_equal [ "passw" ], settings.dig("redact", "filters")
  end

  def test_the_config_carries_strict_privacy_and_the_apps_own_keys
    strict = config({ "PACKRAT_PRIVACY" => "strict" })
    strict.redact_keys = %w[ssn]
    settings = data_config(middleware(setup: run_setup(strict)))

    assert_equal true, settings["strict"]
    assert_equal [ "ssn" ], settings.dig("redact", "keys")
  end

  def test_the_config_names_the_signed_in_user
    Object.const_set(:Current, Class.new { def self.user = Struct.new(:id).new(42) })

    assert_equal({ "id" => "42" }, data_config(middleware)["user"])
  ensure
    Object.send(:remove_const, :Current) if defined?(::Current)
  end

  def test_the_config_marks_an_admin
    Object.const_set(:Current, Class.new { def self.user = Struct.new(:id, :admin?).new(42, true) })

    assert_equal({ "id" => "42", "admin" => true }, data_config(middleware)["user"])
  ensure
    Object.send(:remove_const, :Current) if defined?(::Current)
  end

  def test_without_a_current_user_the_controller_names_the_user
    controller = Class.new(PagesController) { def current_user = Struct.new(:id, :admin?).new(9, false) }

    assert_equal({ "id" => "9" }, data_config(middleware, with_controller(controller.new("show")))["user"])
  end

  def test_a_signed_out_controller_names_no_user
    signed_out = Class.new(PagesController) { def current_user = nil }
    hidden = Class.new(PagesController) do
      private

      def current_user = Struct.new(:id).new(9)
    end

    assert_nil data_config(middleware, with_controller(signed_out.new("show")))["user"]
    assert_nil data_config(middleware, with_controller(hidden.new("show")))["user"]
  end

  def test_current_user_wins_over_the_controller
    Object.const_set(:Current, Class.new { def self.user = Struct.new(:id).new(42) })
    controller = Class.new(PagesController) { def current_user = Struct.new(:id).new(9) }

    assert_equal({ "id" => "42" }, data_config(middleware, with_controller(controller.new("show")))["user"])
  ensure
    Object.send(:remove_const, :Current) if defined?(::Current)
  end

  def test_a_user_lookup_that_raises_names_no_user
    Object.const_set(:Current, Class.new { def self.user = raise("no session") })
    assert_nil data_config(middleware)["user"]

    controller = Class.new(PagesController) { def current_user = raise("no session") }
    assert_nil data_config(middleware, with_controller(controller.new("show")))["user"]
  ensure
    Object.send(:remove_const, :Current) if defined?(::Current)
  end

  def test_adds_the_content_security_policy_nonce
    request = env
    request["action_dispatch.content_security_policy"] = ActionDispatch::ContentSecurityPolicy.new { |policy| policy.script_src :self }
    request["action_dispatch.content_security_policy_nonce_generator"] = ->(_) { "n0nce" }

    assert_match %r{<script defer src="#{SCRIPT}" data-config="[^"]+" nonce="n0nce"></script>}, page(middleware, request)
  end

  def test_leaves_alone_what_is_not_a_whole_html_page
    assert_unchanged middleware(headers: { "content-type" => "application/json" })
    assert_unchanged middleware(body: Body.new("<p>no head</p>"))
    assert_unchanged middleware, env.merge("HTTP_TURBO_FRAME" => "cart")
    assert_unchanged middleware(headers: { "content-type" => "text/html", "content-disposition" => "attachment; filename=page.html" })
    assert_unchanged middleware(headers: { "content-type" => "text/html", "content-encoding" => "gzip" })
    assert_unchanged middleware, env.merge("REQUEST_METHOD" => "POST")

    streamed = Object.new.tap { |body| body.define_singleton_method(:each) { |&block| block.call(PAGE) } }
    assert_same streamed, middleware(body: streamed).call(env)[2]
  end

  def test_nothing_when_browser_events_are_off
    off = config
    off.browser = false
    assert_unchanged middleware(setup: run_setup(off))
    assert_unchanged middleware(setup: run_setup(config({ "PACKRAT_INGEST_KEY" => nil })))
    assert_unchanged Packrat::Browser.new(app), env
  end

  def test_a_lambda_chooses_by_request
    choose = config
    choose.browser = ->(request) { request.path.start_with?("/shop") }
    middleware = middleware(setup: run_setup(choose))

    assert_includes page(middleware, env("/shop/cart")), SCRIPT
    assert_unchanged middleware, env("/admin")
  end

  def test_controller_macros_win_for_the_actions_they_name
    off = config
    off.browser = false
    on = run_setup(config)

    controller = Class.new(PagesController) { packrat_browser only: :show }
    assert_includes page(middleware(setup: run_setup(off)), env.merge("action_controller.instance" => controller.new("show"))), SCRIPT
    assert_unchanged middleware(setup: run_setup(off)), env.merge("action_controller.instance" => controller.new("index"))

    skipped = Class.new(PagesController) { skip_packrat_browser except: %w[index] }
    assert_unchanged middleware(setup: on), env.merge("action_controller.instance" => skipped.new("show"))
    assert_includes page(middleware(setup: on), env.merge("action_controller.instance" => skipped.new("index"))), SCRIPT

    child = Class.new(skipped) { packrat_browser only: :show }
    assert_includes page(middleware(setup: on), env.merge("action_controller.instance" => child.new("show"))), SCRIPT
    assert_unchanged middleware(setup: on), env.merge("action_controller.instance" => skipped.new("show"))
  end

  def test_a_failure_leaves_the_page_as_it_was
    rails = defined?(::Rails) ? ::Rails : Object.const_set(:Rails, Module.new)
    logger = @logger
    rails.define_singleton_method(:logger) { logger }
    Packrat.instance_variable_set(:@config, config)
    setup = run_setup(config)
    setup.define_singleton_method(:service) { raise "broken #{CANARY}" }

    assert_equal [ PAGE ], middleware(setup:).call(env)[2]
    assert_match "Packrat: browser events failed (RuntimeError: broken [redacted]); the app runs without it", log
  ensure
    Packrat.instance_variable_set(:@config, nil)
    rails.singleton_class.remove_method(:logger)
  end

  def test_the_built_script
    script = File.read(Packrat::Browser::FILE)

    assert_match %r{\A/\*! @datadog/browser-rum-slim \d+\.\d+\.\d+ \| Apache-2\.0 \|.*Bundled with a different entry point by packrat-rails}, script
    refute_match(/DD_RUM\s*=|defineGlobal\([^)]*DD_RUM/, script)
    assert_includes script, "data-config"
    assert_includes File.read(File.expand_path("../LICENSE-THIRD-PARTY", __dir__)), "Apache License"
  end

  private

  def app(body: nil, headers: { "content-type" => "text/html; charset=utf-8", "content-length" => PAGE.bytesize.to_s })
    ->(_env) { [ 200, headers.dup, body || Body.new(PAGE) ] }
  end

  def middleware(setup: nil, **app)
    Packrat::Browser.new(app(**app), setup: setup || run_setup(config))
  end

  def env(path = "/")
    Rack::MockRequest.env_for(path)
  end

  def page(middleware, request = env)
    +"".tap { |html| middleware.call(request)[2].each { |part| html << part } }
  end

  def data_config(middleware, request = env)
    JSON.parse(CGI.unescapeHTML(page(middleware, request)[/data-config="([^"]+)"/, 1]))
  end

  def with_controller(controller)
    env.merge("action_controller.instance" => controller)
  end

  def assert_unchanged(middleware, request = env)
    html = page(middleware, request)
    refute_includes html, "<script", "no script on #{request['PATH_INFO']}"
  end
end
