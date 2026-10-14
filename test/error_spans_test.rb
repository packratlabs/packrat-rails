require "test_helper"

# Ported from Colorbook's ErrorReporting::SpanSubscriber tests.
class ErrorSpansTest < PackratTest
  def setup
    super
    @exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
    sdk_provider.add_span_processor(OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(@exporter))
  end

  def test_an_error_inside_a_span_is_an_exception_event_on_that_span
    OpenTelemetry.tracer_provider.tracer("test").in_span("InventoryJob") do
      report(raised("boom"), severity: :error, context: { item_id: "i-1", attempt: 2, tags: { brand_name: "gap" } })
    end

    span = @exporter.finished_spans.sole
    attributes = exception_event(span).attributes
    assert_equal "InventoryJob", span.name
    assert_equal "RuntimeError", attributes["exception.type"]
    assert_equal "boom", attributes["exception.message"]
    assert_equal true, attributes["exception.handled"]
    assert_equal "error", attributes["rails.error.severity"]
    assert_equal "application", attributes["rails.error.source"]
    assert_equal "i-1", attributes["rails.error.context.item_id"]
    assert_equal 2, attributes["rails.error.context.attempt"]
    assert_equal "gap", attributes["rails.error.context.brand_name"]
    assert_includes attributes["exception.stacktrace"], "error_spans_test.rb"
  end

  def test_an_error_outside_a_span_gets_a_root_span_of_its_own
    report(raised("boom"), severity: :warning)

    span = @exporter.finished_spans.sole
    assert_equal "Rails.error", span.name
    assert_equal "warning", exception_event(span).attributes["rails.error.severity"]
  end

  def test_a_message_is_recorded_as_an_exception
    report("No fit facet for category=jeans", severity: :warning)

    attributes = exception_event(@exporter.finished_spans.sole).attributes
    assert_equal "RuntimeError", attributes["exception.type"]
    assert_equal "No fit facet for category=jeans", attributes["exception.message"]
  end

  def test_the_controller_and_job_are_left_out_and_a_hash_becomes_json
    report(raised("boom"), severity: :error, context: { controller: Object.new, job: Object.new, csrf: { path: "/sign_in" }, gone: nil })

    attributes = exception_event(@exporter.finished_spans.sole).attributes
    refute attributes.key?("rails.error.context.controller")
    refute attributes.key?("rails.error.context.job")
    refute attributes.key?("rails.error.context.gone")
    assert_equal({ "path" => "/sign_in" }, JSON.parse(attributes["rails.error.context.csrf"]))
  end

  def test_credentials_are_redacted_from_the_message_the_stack_and_the_context
    report(raised("fetch failed url=https://api.scrapfly.io/scrape?api_key=s3cret"), severity: :error,
           context: { url: "https://x.test/?token=t0ken" })

    attributes = exception_event(@exporter.finished_spans.sole).attributes
    refute_includes attributes["exception.message"], "s3cret"
    refute_includes attributes["exception.stacktrace"], "s3cret"
    refute_includes attributes["rails.error.context.url"], "t0ken"
  end

  def test_an_error_that_escapes_a_request_or_a_sidekiq_job_is_left_to_the_instrumentation
    %w[application.action_dispatch job.sidekiq].each do |source|
      report(raised("boom"), severity: :error, handled: false, source:)
    end

    assert_empty @exporter.finished_spans
  end

  def test_an_unhandled_error_from_a_runner_script_is_recorded
    report(raised("boom"), severity: :error, handled: false, source: "application.runner.railties")

    assert_equal false, exception_event(@exporter.finished_spans.sole).attributes["exception.handled"]
  end

  def test_a_cache_store_error_is_not_recorded
    report(raised("Redis down"), severity: :warning, source: "redis_cache_store.active_support")

    assert_empty @exporter.finished_spans
  end

  def test_a_failure_inside_does_not_raise
    OpenTelemetry.tracer_provider.stub(:tracer, ->(*) { raise StandardError, "exporter gone" }) do
      report(raised("boom"), severity: :error)
    end

    assert_match "exporter gone", @otel_log.string
  end

  private

  def report(error, severity:, context: {}, handled: true, source: "application")
    Packrat::Otel::ErrorSpans.new.report(error, handled:, severity:, context:, source:)
  end

  def raised(message)
    raise message
  rescue RuntimeError => error
    error
  end

  def exception_event(span)
    span.events.find { |event| event.name == "exception" }
  end
end
