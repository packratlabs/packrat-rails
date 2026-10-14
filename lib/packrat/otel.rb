require "uri"

module Packrat
  module Otel
    CLASSES = {
      "rack" => "OpenTelemetry::Instrumentation::Rack",
      "action_pack" => "OpenTelemetry::Instrumentation::ActionPack",
      "active_job" => "OpenTelemetry::Instrumentation::ActiveJob",
      "active_record" => "OpenTelemetry::Instrumentation::ActiveRecord",
      "net_http" => "OpenTelemetry::Instrumentation::Net::HTTP",
      "pg" => "OpenTelemetry::Instrumentation::PG",
      "mysql2" => "OpenTelemetry::Instrumentation::Mysql2",
      "logger" => "OpenTelemetry::Instrumentation::Logger"
    }.freeze
    # The health check runs every few seconds and would otherwise be most of what is stored.
    OPTIONS = { "rack" => { untraced_endpoints: [ "/up" ] } }.freeze
    # These install through the Active Support instrumentation and do not require it themselves.
    PREREQUISITES = { "action_view" => "active_support" }.freeze
    # These set up in an after_initialize block of their own Railtie, which cannot run once boot has
    # reached Packrat's.
    BOOT_ONLY = %w[action_mailer active_storage].freeze
    EXIT_TIMEOUT = 5

    # dogstatsd-ruby defines Datadog::Statsd without the tracer, hence the method check.
    def self.datadog?
      !!(defined?(::Datadog) && ::Datadog.respond_to?(:configuration))
    end

    # The one decision, made at the end of boot: configure OpenTelemetry when nothing has, add a
    # Packrat exporter beside the app's own when something has, and stay out of Datadog's way.
    class Setup
      attr_reader :outcome, :line, :installed, :warnings

      def initialize(config:, logger:, errors:)
        @config = config
        @logger = logger
        @errors = errors
        @installed = []
        @warnings = []
      end

      def call
        provider = OpenTelemetry.tracer_provider
        if !@config.enabled? then off
        elsif Otel.datadog? then datadog
        elsif provider.is_a?(OpenTelemetry::SDK::Trace::TracerProvider) then append(provider)
        else configure
        end
        @logger.info(@line) if @line
        self
      end

      # The Rack span, for the middleware the Railtie put in the stack before this decision was made.
      def rack(app)
        return app unless @outcome == :configured && @installed.include?("rack")

        middleware, *args = instrumentation("rack").middleware_args
        middleware.new(app, *args)
      rescue StandardError, LoadError => error
        failed("rack middleware", error)
        app
      end

      private

      def off
        @outcome = :off
        @line = @config.off_reason && "Packrat: #{@config.off_reason}"
      end

      def datadog
        @outcome = :datadog
        @line = "Packrat: Datadog found; configure the Agent to dual-ship, see https://packrat.sh/docs/datadog"
      end

      def configure
        logs = step("logs SDK") { load_logs }
        spans = step("traces exporter") { span_processor }
        records = logs && step("logs exporter") { log_record_processor }
        return @line = "Packrat: OpenTelemetry was not configured, so nothing is sent" unless spans && step("SDK") { configure_sdk(spans, records) }

        @outcome = :configured
        step("sampler") { use_sampler } unless @config.set?("OTEL_TRACES_SAMPLER")
        @config.instrumentations.each { |name| step("instrumentation #{name}") { install(name) } }
        step("Rails.error") { @errors.subscribe(ErrorSpans.new) }
        step("at_exit") { at_exit { shutdown_providers } }
        @line = "Packrat: sending #{signals(records)} for #{@config.service_name}/#{@config.environment} " \
                "to #{@config.url} (#{@installed.join(', ')})"
      end

      def append(provider)
        if @config.app_exports_to_packrat?
          @outcome = :already
          return @line = "Packrat: the app's OpenTelemetry exporter already sends to #{@config.url}"
        end

        spans = step("traces exporter") { span_processor }
        return @line = "Packrat: the app's OpenTelemetry was left alone, and nothing is sent" unless spans && step("traces processor") { provider.add_span_processor(spans) }

        @outcome = :appended
        records = sdk_logger_provider && logger_instrumented? && step("logs exporter") { log_record_processor }
        records = nil unless records && step("logs processor") { sdk_logger_provider.add_log_record_processor(records) }
        errors = !error_spans? && step("Rails.error") { @errors.subscribe(ErrorSpans.new) }
        step("at_exit") { at_exit { [ spans, records ].compact.each { |processor| processor.shutdown(timeout: EXIT_TIMEOUT) } } }

        attributes = provider.resource.attribute_enumerator.to_h
        name = attributes["service.name"]
        environment = attributes["deployment.environment.name"] || attributes["deployment.environment"]
        @line = "Packrat: sending a copy of the app's #{signals(records)} for #{name}/#{environment} to #{@config.url}"
        @line += "; Rails.error is now recorded on spans, which the app's own exporter also receives" if errors
        if name.nil? || name.start_with?("unknown_service")
          @line += ". Warning: the app's OpenTelemetry resource has no service.name, and the setup screen looks for the app by name"
        end
      end

      # Every step fails on its own: a warning that names it, and boot goes on. LoadError is not a
      # StandardError, and a missing gem is the likely failure.
      def step(name)
        yield || true
      rescue StandardError, LoadError => error
        failed(name, error)
        nil
      end

      def failed(name, error)
        text = Packrat.redact(error.message.lines.first.to_s.strip, @config.key)
        message = "Packrat: #{name} failed (#{error.class}: #{text}); the app runs without it"
        @warnings << message
        @logger.warn(message)
      end

      # Required here rather than at the top of the gem: the logs SDK prepends a hook to
      # SDK::Configurator, and an app that configures OpenTelemetry itself would then get a logger
      # provider exporting to localhost:4318 that it never asked for.
      def load_logs
        require "opentelemetry-logs-sdk"
        require "opentelemetry-exporter-otlp-logs"
      end

      def span_processor
        OpenTelemetry::SDK::Trace::Export::BatchSpanProcessor.new(
          ScrubbingSpanExporter.new(OpenTelemetry::Exporter::OTLP::Exporter.new(endpoint: @config.traces_endpoint, headers: @config.headers))
        )
      end

      def log_record_processor
        OpenTelemetry::SDK::Logs::Export::BatchLogRecordProcessor.new(
          ScrubbingLogExporter.new(OpenTelemetry::Exporter::OTLP::Logs::LogsExporter.new(endpoint: @config.logs_endpoint, headers: @config.headers))
        )
      rescue NameError => error
        raise unless error.name == :Utilities

        # The logs exporter from 0.6 calls Common::Utilities, which otlp-common has from 0.3, and still
        # declares "~> 0.2"; Bundler keeps an older lock. A bound in the gemspec would need Ruby 3.3.
        raise NameError, "#{error.message}; run bundle update opentelemetry-exporter-otlp-common"
      end

      def configure_sdk(spans, records)
        OpenTelemetry::SDK.configure do |sdk|
          sdk.resource = OpenTelemetry::SDK::Resources::Resource.create(@config.resource_attributes)
          sdk.add_span_processor(spans)
          sdk.add_log_record_processor(records) if records
        end
      end

      def use_sampler
        OpenTelemetry.tracer_provider.sampler =
          OpenTelemetry::SDK::Trace::Samplers.parent_based(root: RootKindSampler.new)
      end

      def install(name)
        raise ArgumentError, "the #{name} instrumentation must load before boot ends, which Packrat does not do" if BOOT_ONLY.include?(name)

        require "opentelemetry-instrumentation-#{PREREQUISITES[name]}" if PREREQUISITES[name]
        require "opentelemetry-instrumentation-#{name}"
        skip_action_pack_railtie if name == "action_pack"
        return unless instrumentation(name).install(OPTIONS.fetch(name, {}))

        prerequisite = PREREQUISITES[name]
        @installed << prerequisite if prerequisite && !@installed.include?(prerequisite) && instrumentation(prerequisite).installed?
        @installed << name
      end

      # Action Pack's install loads a Railtie whose one job is to put the Rack span in the middleware
      # stack. At the end of boot the stack is frozen, so loading it raises; Packrat::RackSpan does
      # that job, and the file is marked as loaded instead.
      def skip_action_pack_railtie
        _, path = $LOAD_PATH.resolve_feature_path("opentelemetry/instrumentation/action_pack/railtie")
        path = File.realpath(path)
        $LOADED_FEATURES << path unless $LOADED_FEATURES.include?(path)
      end

      def instrumentation(name)
        namespace = CLASSES[name] || begin
          constant = OpenTelemetry::Instrumentation.constants.find { |found| found.to_s.downcase == name.delete("_") }
          "OpenTelemetry::Instrumentation::#{constant || raise(NameError, "no instrumentation named #{name}")}"
        end
        Object.const_get("#{namespace}::Instrumentation").instance
      end

      def shutdown_providers
        OpenTelemetry.tracer_provider.shutdown(timeout: EXIT_TIMEOUT)
        OpenTelemetry.logger_provider.shutdown(timeout: EXIT_TIMEOUT) if sdk_logger_provider
      end

      def sdk_logger_provider
        return unless defined?(OpenTelemetry::SDK::Logs::LoggerProvider) && OpenTelemetry.respond_to?(:logger_provider)

        provider = OpenTelemetry.logger_provider
        provider if provider.is_a?(OpenTelemetry::SDK::Logs::LoggerProvider)
      end

      # A logger provider nothing writes to is common: the logs SDK makes one whenever it is loaded,
      # and an app may send its log lines through a provider of its own.
      def logger_instrumented?
        defined?(OpenTelemetry::Instrumentation::Logger::Instrumentation) &&
          OpenTelemetry::Instrumentation::Logger::Instrumentation.instance.installed?
      end

      # ActiveSupport::ErrorReporter keeps its subscribers private.
      def error_spans?
        Array(@errors.instance_variable_get(:@subscribers)).any? { |subscriber| subscriber.class.name.to_s.end_with?("ErrorSpans") }
      end

      def signals(records)
        records ? "traces and logs" : "traces"
      end
    end
  end
end
