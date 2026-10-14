require "minitest/autorun"
require "minitest/mock"
require "stringio"
require "packrat"
require "opentelemetry-logs-sdk"

class PackratTest < Minitest::Test
  CANARY = "packrat_ingest_CANARY_KEY_DO_NOT_PRINT_9c1e".freeze
  # Port 9 is discard: nothing listens, and nothing in these tests waits for an export.
  URL = "http://127.0.0.1:9".freeze

  class Errors
    attr_reader :subscribers

    def initialize(*subscribers)
      @subscribers = subscribers
    end

    def subscribe(subscriber)
      @subscribers << subscriber
    end
  end

  class FakeInstrumentation
    attr_reader :config

    def initialize(present: true)
      @present = present
    end

    def install(config)
      @config = config
      @present
    end
  end

  def setup
    @log = StringIO.new
    @logger = Logger.new(@log)
    @otel_log = StringIO.new
    OpenTelemetry.logger = Logger.new(@otel_log)
    OpenTelemetry.instance_variable_set(:@tracer_provider, OpenTelemetry::Internal::ProxyTracerProvider.new)
    # opentelemetry-logs-api 0.7 moved the global from OpenTelemetry to OpenTelemetry::Internal.
    holder = OpenTelemetry::Internal.respond_to?(:logger_provider) ? OpenTelemetry::Internal : OpenTelemetry
    holder.instance_variable_set(:@logger_provider, OpenTelemetry::Internal::ProxyLoggerProvider.new)
    @errors = Errors.new
  end

  def teardown
    [ OpenTelemetry.tracer_provider, OpenTelemetry.logger_provider ].each do |provider|
      provider.shutdown(timeout: 0.1) if provider.respond_to?(:shutdown)
    end
  end

  def config(env = {}, rails_env: "production", app_name: "shop")
    Packrat::Config.new(env: { "PACKRAT_INGEST_KEY" => CANARY, "PACKRAT_INGEST_URL" => URL }.merge(env),
                        rails_env:, app_name:)
  end

  # Runs Setup with fake instrumentations and no at_exit hook, so a test leaves nothing behind.
  def run_setup(config, instrumentations: Hash.new { |hash, name| hash[name] = FakeInstrumentation.new })
    setup = Packrat::Otel::Setup.new(config:, logger: @logger, errors: @errors)
    @instrumentations = instrumentations
    setup.stub(:instrumentation, ->(name) { instrumentations[name] }) do
      setup.stub(:at_exit, nil) { yield setup if block_given?; setup.call }
    end
  end

  def sdk_provider(service_name: "shop")
    OpenTelemetry::SDK::Trace::TracerProvider.new(
      resource: OpenTelemetry::SDK::Resources::Resource.create("service.name" => service_name, "deployment.environment.name" => "production")
    ).tap { |provider| OpenTelemetry.tracer_provider = provider }
  end

  # Behind the scrubbing wrapper, the OTLP exporter itself.
  def exporters(provider)
    provider.instance_variable_get(:@span_processors).filter_map do |processor|
      exporter = processor.instance_variable_get(:@exporter)
      exporter.is_a?(Packrat::Otel::ScrubbingSpanExporter) ? exporter.instance_variable_get(:@exporter) : exporter
    end
  end

  def log
    @log.string
  end
end
