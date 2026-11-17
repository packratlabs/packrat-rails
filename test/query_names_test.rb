require "test_helper"

class QueryNamesTest < PackratTest
  def setup
    super
    @exported = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
    @provider = sdk_provider
    @provider.add_span_processor(Packrat::Otel::QueryNames.new)
    @provider.add_span_processor(OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(@exported))
    @subscription = ActiveSupport::Notifications.subscribe(Packrat::Otel::QueryNames::EVENT, Packrat::Otel::QueryNames::Names.new)
  end

  def teardown
    ActiveSupport::Notifications.unsubscribe(@subscription)
    super
  end

  def query(name, scope: "OpenTelemetry::Instrumentation::PG", span: "EXECUTE shop_production")
    ActiveSupport::Notifications.instrument("sql.active_record", name:, sql: "SELECT 1") do
      @provider.tracer(scope).in_span(span, kind: :client, attributes: { "db.statement" => "SELECT 1" }) { yield if block_given? }
    end
  end

  def names = @exported.finished_spans.map(&:name)

  def test_a_driver_span_takes_the_name_rails_gives_its_query_and_keeps_its_sql
    query("Order Load")
    query("Order Create", scope: "OpenTelemetry::Instrumentation::Mysql2", span: "INSERT shop_production")

    assert_equal [ "Order Load", "Order Create" ], names
    assert_equal "SELECT 1", @exported.finished_spans.first.attributes["db.statement"]
  end

  def test_a_query_rails_did_not_name_and_a_span_of_another_library_keep_their_names
    query(nil)
    query("")
    query("Order Load", scope: "OpenTelemetry::Instrumentation::Net::HTTP", span: "GET")
    @provider.tracer("OpenTelemetry::Instrumentation::PG").in_span("SELECT shop_production", kind: :client) { nil }

    assert_equal [ "EXECUTE shop_production", "EXECUTE shop_production", "GET", "SELECT shop_production" ], names
  end

  def test_a_query_inside_another_takes_its_own_name_and_the_outer_one_comes_back
    query("Order Load") do
      query("SCHEMA", span: "SELECT pg_attribute")
      @provider.tracer("OpenTelemetry::Instrumentation::PG").in_span("EXECUTE shop_production", kind: :client) { nil }
    end

    assert_equal [ "SCHEMA", "Order Load", "Order Load" ], names
    assert_empty Packrat::Otel::QueryNames::Names.stack
  end

  def test_a_query_that_raises_still_leaves_its_name
    assert_raises(RuntimeError) { query("Order Create") { raise "duplicate key" } }
    query(nil)

    assert_equal [ "Order Create", "EXECUTE shop_production" ], names
  end
end
