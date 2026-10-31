require "test_helper"

class SetupTest < PackratTest
  def test_configure_when_no_provider_exists
    setup = run_setup(config({ "BUILD_COMMIT" => "abc123" }))
    provider = OpenTelemetry.tracer_provider

    assert_equal :configured, setup.outcome
    assert_kind_of OpenTelemetry::SDK::Trace::TracerProvider, provider
    exporter = exporters(provider).sole
    assert_equal "#{URL}/v1/traces", exporter.instance_variable_get(:@uri).to_s
    assert_equal CANARY, exporter.instance_variable_get(:@headers)["Authorization"]

    attributes = provider.resource.attribute_enumerator.to_h
    assert_equal "shop", attributes["service.name"]
    assert_equal "production", attributes["deployment.environment.name"]
    assert_equal "abc123", attributes["service.version"]
    assert_equal "packrat-rails", attributes["telemetry.distro.name"]
    assert_equal Packrat::VERSION, attributes["telemetry.distro.version"]

    assert_kind_of OpenTelemetry::SDK::Logs::LoggerProvider, OpenTelemetry.logger_provider
    assert_match "RootKindSampler", provider.sampler.description
    installed = %w[rack action_pack action_view active_job active_record net_http pg mysql2 sidekiq redis aws_sdk concurrent_ruby rake logger]
    assert_equal installed, setup.installed
    assert_equal({ untraced_endpoints: [ "/up" ] }, @instrumentations["rack"].config)
    assert_kind_of Packrat::Otel::ErrorSpans, @errors.subscribers.sole
    assert_equal "Packrat: sending traces and logs for shop/production to #{URL} " \
                 "(#{installed.join(', ')}); redacting email and ip", setup.line
    assert_includes log, setup.line
  end

  def test_configure_lists_only_what_installed
    instrumentations = Hash.new { |hash, name| hash[name] = FakeInstrumentation.new(present: %w[rack action_pack active_job active_record net_http logger].include?(name)) }
    setup = run_setup(config, instrumentations:)

    assert_equal %w[rack action_pack active_job active_record net_http logger], setup.installed
  end

  def test_configure_leaves_a_sampler_named_by_the_environment
    run_setup(config({ "OTEL_TRACES_SAMPLER" => "always_on" }))

    refute_match "RootKindSampler", OpenTelemetry.tracer_provider.sampler.description
  end

  def test_append_beside_the_apps_own_provider
    provider = sdk_provider
    own = OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new)
    provider.add_span_processor(own)
    sampler = provider.sampler

    setup = run_setup(config)

    assert_equal :appended, setup.outcome
    assert_same provider, OpenTelemetry.tracer_provider
    assert_same sampler, provider.sampler
    processors = provider.instance_variable_get(:@span_processors)
    assert_same own, processors.first
    assert_equal "#{URL}/v1/traces", exporters(provider).last.instance_variable_get(:@uri).to_s
    assert_empty setup.installed
    assert_equal "Packrat: sending a copy of the app's traces for shop/production to #{URL}; " \
                 "redacting email and ip; Rails.error is now recorded on spans, which the app's own exporter also receives", setup.line
  end

  def test_append_adds_logs_when_the_apps_log_lines_reach_its_logger_provider
    sdk_provider
    logger_provider = OpenTelemetry::SDK::Logs::LoggerProvider.new
    OpenTelemetry.logger_provider = logger_provider

    setup = run_setup(config) { |subject| subject.define_singleton_method(:logger_instrumented?) { true } }

    assert_equal 1, logger_provider.instance_variable_get(:@log_record_processors).size
    assert_match "traces and logs", setup.line
  end

  def test_append_adds_no_logs_when_nothing_writes_to_the_logger_provider
    sdk_provider
    logger_provider = OpenTelemetry::SDK::Logs::LoggerProvider.new
    OpenTelemetry.logger_provider = logger_provider

    setup = run_setup(config) { |subject| subject.define_singleton_method(:logger_instrumented?) { false } }

    assert_empty logger_provider.instance_variable_get(:@log_record_processors)
    assert_match "app's traces for", setup.line
  end

  def test_append_leaves_an_error_subscriber_the_app_already_has
    sdk_provider
    error_spans = Class.new { def self.name = "Telemetry::ErrorSpans" }.new
    @errors = Errors.new(error_spans)

    setup = run_setup(config)

    assert_equal [ error_spans ], @errors.subscribers
    refute_match "Rails.error", setup.line
  end

  def test_append_warns_when_the_resource_has_no_service_name
    OpenTelemetry.tracer_provider = OpenTelemetry::SDK::Trace::TracerProvider.new

    assert_match "no service.name", run_setup(config).line
  end

  def test_append_adds_nothing_when_the_apps_exporter_already_sends_to_packrat
    provider = sdk_provider
    setup = run_setup(config({ "OTEL_EXPORTER_OTLP_ENDPOINT" => "#{URL}/" }))

    assert_equal :already, setup.outcome
    assert_empty exporters(provider)
    assert_empty @errors.subscribers
    assert_equal "Packrat: the app's OpenTelemetry exporter already sends to #{URL}", setup.line
  end

  def test_datadog_is_left_alone
    Object.const_set(:Datadog, Module.new { def self.configuration = nil })
    setup = run_setup(config)

    assert_equal :datadog, setup.outcome
    assert_kind_of OpenTelemetry::Internal::ProxyTracerProvider, OpenTelemetry.tracer_provider
    assert_empty @errors.subscribers
    assert_equal "Packrat: Datadog found; configure the Agent to dual-ship, see https://packrat.sh/docs/datadog", setup.line
  ensure
    Object.send(:remove_const, :Datadog) if defined?(::Datadog)
  end

  def test_statsd_alone_is_not_datadog
    Object.const_set(:Datadog, Module.new)

    assert_equal :configured, run_setup(config).outcome
  ensure
    Object.send(:remove_const, :Datadog) if defined?(::Datadog)
  end

  def test_off_without_a_key
    setup = run_setup(config({ "PACKRAT_INGEST_KEY" => nil }))

    assert_equal :off, setup.outcome
    assert_kind_of OpenTelemetry::Internal::ProxyTracerProvider, OpenTelemetry.tracer_provider
    assert_equal "Packrat: no ingest key is set (PACKRAT_INGEST_KEY or config.ingest_key), so nothing is sent", setup.line
  end

  def test_test_environment_is_silent
    setup = run_setup(config(rails_env: "test"))

    assert_equal :off, setup.outcome
    assert_nil setup.line
    assert_empty log
  end

  def test_error_spans_record_on_a_span_of_their_own
    exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
    provider = sdk_provider
    provider.add_span_processor(OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter))

    Packrat::Otel::ErrorSpans.new.report(RuntimeError.new("boom"), handled: true, severity: :error, context: {})

    span = exporter.finished_spans.sole
    assert_equal "Rails.error", span.name
    assert_equal "boom", span.events.sole.attributes["exception.message"]
    assert_equal true, span.events.sole.attributes["exception.handled"]
  end

  def test_root_kind_sampler
    sampler = Packrat::Otel::RootKindSampler.new
    decide = ->(kind, name = "x") do
      sampler.should_sample?(trace_id: "t", parent_context: OpenTelemetry::Context.empty, links: [], name:, kind:, attributes: {}).sampled?
    end

    assert decide.(:server)
    assert decide.(:consumer)
    assert decide.(:internal, "Rails.error")
    assert decide.(:internal, "rake.invoke")
    assert decide.(:internal, "rake.execute")
    refute decide.(:client)
    refute decide.(:internal)
  end
end
