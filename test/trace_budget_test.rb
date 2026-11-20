require "test_helper"

class TraceBudgetTest < Minitest::Test
  def setup
    @exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
    @provider = OpenTelemetry::SDK::Trace::TracerProvider.new(
      sampler: OpenTelemetry::SDK::Trace::Samplers.parent_based(
        root: Packrat::Otel::RootKindSampler.new,
        local_parent_sampled: Packrat::Otel::TraceBudget.new(spans: 5, traces: 2)
      )
    )
    @provider.add_span_processor(OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(@exporter))
    @tracer = @provider.tracer("test")
  end

  def test_a_trace_keeps_its_budget_and_drops_the_rest_with_their_children
    @tracer.in_span("solid_queue:start", kind: :server) do
      10.times do |i|
        @tracer.in_span("poll #{i}") { @tracer.in_span("query #{i}") { } }
      end
    end

    names = @exporter.finished_spans.map(&:name)
    assert_equal [ "query 0", "poll 0", "query 1", "poll 1", "poll 2", "solid_queue:start" ], names
  end

  def test_each_trace_has_its_own_budget
    2.times { @tracer.in_span("GET /", kind: :server) { 6.times { |i| @tracer.in_span("sql #{i}") { } } } }

    assert_equal 12, @exporter.finished_spans.size
  end

  def test_the_oldest_trace_is_forgotten_past_the_limit
    budget = Packrat::Otel::TraceBudget.new(spans: 1, traces: 2)
    decide = ->(trace_id) do
      budget.should_sample?(trace_id:, parent_context: OpenTelemetry::Context.empty, links: [], name: "x", kind: :internal, attributes: {}).sampled?
    end

    assert decide.("a")
    refute decide.("a")
    assert decide.("b")
    assert decide.("c")
    assert decide.("a"), "a was forgotten when c arrived"
    refute decide.("c")
  end
end
