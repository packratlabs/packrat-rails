require "erb"
require "json"
require "active_support/concern"
require "active_support/core_ext/class/attribute"

module Packrat
  # Serves the page script and adds it to each HTML page before </head>. It sits at the end of the
  # stack, so it sees the controller that rendered the page and the response before anything wraps it.
  class Browser
    PATH = "/packrat/browser-#{VERSION}.js".freeze
    FILE = File.expand_path("browser/packrat-browser.js", __dir__)
    HEAD = %r{</head>}in
    SCRIPT_HEADERS = { "content-type" => "text/javascript", "cache-control" => "public, max-age=31536000, immutable" }.freeze

    # packrat_browser and skip_packrat_browser, for a controller to choose its own pages. The last
    # one that names an action wins.
    module Controller
      extend ActiveSupport::Concern

      included do
        class_attribute :packrat_browser_rules, instance_accessor: false, instance_predicate: false, default: [].freeze
      end

      class_methods do
        def packrat_browser(only: nil, except: nil)
          add_packrat_browser_rule(true, only, except)
        end

        def skip_packrat_browser(only: nil, except: nil)
          add_packrat_browser_rule(false, only, except)
        end

        # true or false when a rule names the action, nil when none does.
        def packrat_browser_choice(action)
          action = action.to_s
          rule = packrat_browser_rules.reverse.find do |_, only, except|
            (only.nil? || only.include?(action)) && (except.nil? || !except.include?(action))
          end
          rule&.first
        end

        private

        def add_packrat_browser_rule(choice, only, except)
          names = ->(list) { Array(list).map(&:to_s).freeze unless list.nil? }
          self.packrat_browser_rules = [ *packrat_browser_rules, [ choice, names.(only), names.(except) ].freeze ].freeze
        end
      end
    end

    def initialize(app, setup: nil)
      @app = app
      @setup = setup
    end

    def call(env)
      return script(env) if env["PATH_INFO"] == PATH && %w[GET HEAD].include?(env["REQUEST_METHOD"])

      status, headers, body = @app.call(env)
      return [ status, headers, body ] unless soft(false) { inject?(env, headers, body) }

      parts = body.to_ary
      body.close if body.respond_to?(:close)
      [ status, headers, soft(parts) { insert(env, headers, parts) } ]
    end

    private

    def setup
      @setup || Packrat.setup
    end

    def script(env)
      @script ||= File.binread(FILE).freeze
      headers = SCRIPT_HEADERS.merge("content-length" => @script.bytesize.to_s)
      [ 200, headers, env["REQUEST_METHOD"] == "HEAD" ? [] : [ @script ] ]
    end

    # Only a whole HTML page that is buffered and readable as it is: never a stream, a download, a
    # compressed body or a Turbo Frame.
    def inject?(env, headers, body)
      setup&.browser? && env["REQUEST_METHOD"] == "GET" && !env.key?("HTTP_TURBO_FRAME") &&
        header(headers, "content-type").to_s.start_with?("text/html") &&
        header(headers, "content-encoding").nil? &&
        !header(headers, "content-disposition").to_s.strip.downcase.start_with?("attachment") &&
        body.respond_to?(:to_ary) && !streaming?(env) && page?(env)
    end

    def streaming?(env)
      controller = env["action_controller.instance"]
      defined?(ActionController::Live) && controller.is_a?(ActionController::Live)
    end

    def page?(env)
      controller = env["action_controller.instance"]
      choice = controller.class.packrat_browser_choice(controller.action_name) if controller.class.respond_to?(:packrat_browser_choice)
      return choice unless choice.nil?

      setting = setup.config.browser
      setting.respond_to?(:call) ? !!setting.call(request(env)) : setting != false
    end

    def insert(env, headers, parts)
      html = parts.join
      bytes = html.b
      at = bytes.index(HEAD)
      return parts unless at

      page = bytes.insert(at, tag(env).b).force_encoding(html.encoding)
      length = headers.keys.find { |key| key.to_s.casecmp?("content-length") }
      headers[length] = page.bytesize.to_s if length
      [ page ]
    end

    def tag(env)
      nonce = nonce(env)
      %(<script defer src="#{ERB::Util.html_escape("#{env['SCRIPT_NAME']}#{PATH}")}" ) +
        %(data-config="#{ERB::Util.html_escape(JSON.generate(settings.merge(user: user(env)).compact, ascii_only: true))}") +
        (nonce ? %( nonce="#{ERB::Util.html_escape(nonce)}") : "") + "></script>"
    end

    def settings
      @settings ||= begin
        config = setup.config
        intake = [ setup.service, setup.environment, config.key ].map { |part| ERB::Util.url_encode(part) }.join("/")
        {
          intake: "#{config.url}/rum/#{intake}",
          service: setup.service,
          env: setup.environment,
          version: setup.version,
          # Packrat names the browser's source by the package before the slash, as it names the server's.
          packrat: "packrat-rails/#{VERSION}",
          strict: config.strict?,
          redact: {
            segments: Otel::Scrubber::CREDENTIAL_SEGMENTS,
            keys: config.redact_keys,
            filters: Array(setup.filters).filter_map { |filter| filter.to_s if filter.is_a?(String) || filter.is_a?(Symbol) }
          }
        }.compact.freeze
      end
    end

    def user(env)
      person = signed_in(env)
      return if person&.id.nil?

      { id: person.id.to_s, admin: (true if person.respond_to?(:admin?) && person.admin? == true) }.compact
    rescue StandardError
      nil
    end

    # Current.user, Clearance's session, Devise's Warden, or else a controller's public current_user.
    # Warden#user reads the session only; it runs no authentication strategy.
    def signed_in(env)
      person = ::Current.user if defined?(::Current) && ::Current.respond_to?(:user)
      person ||= env[:clearance].current_user if env[:clearance].respond_to?(:current_user)
      person ||= env["warden"].user if env["warden"].respond_to?(:user)
      return person if person

      controller = env["action_controller.instance"]
      controller.current_user if controller.respond_to?(:current_user)
    end

    def nonce(env)
      return unless defined?(ActionDispatch::Request)

      request = request(env)
      request.content_security_policy_nonce if request.respond_to?(:content_security_policy) && request.content_security_policy
    end

    def request(env)
      defined?(ActionDispatch::Request) ? ActionDispatch::Request.new(env) : Rack::Request.new(env)
    end

    def header(headers, name)
      headers.find { |key, _| key.to_s.casecmp?(name) }&.last
    end

    def soft(fallback)
      yield
    rescue StandardError, LoadError => error
      Packrat.failed("browser events", error) unless @failed
      @failed = true
      fallback
    end
  end
end
