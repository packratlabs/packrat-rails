require "test_helper"

# Ported from Colorbook's Packrat::Scrubber tests, where this code ran in production first.
class ScrubberTest < PackratTest
  Scrubber = Packrat::Otel::Scrubber

  class RecordingExporter
    attr_reader :batches, :flushes, :shutdowns

    def initialize
      @batches = []
      @flushes = 0
      @shutdowns = 0
    end

    def export(batch, timeout: nil)
      @batches << batch
      OpenTelemetry::SDK::Trace::Export::SUCCESS
    end

    def force_flush(timeout: nil)
      @flushes += 1
    end

    def shutdown(timeout: nil)
      @shutdowns += 1
    end
  end

  def scrub(attributes) = Scrubber.scrub_attributes(attributes)

  def test_a_query_string_keeps_the_parameters_that_describe_the_request
    target = "/colors/unapproved?brand_index=0&item_brand_name=target&section=red&panel_image=0"

    assert_equal target, scrub("http.target" => target)["http.target"]
  end

  def test_a_credential_in_the_query_string_is_redacted_and_its_neighbours_are_not
    scrubbed = scrub("http.target" => "/scrape?key=scp-live-abc123&url=https%3A%2F%2Fexample.com&asp=false")

    assert_equal "/scrape?key=[REDACTED]&url=https%3A%2F%2Fexample.com&asp=false", scrubbed["http.target"]
  end

  def test_the_usual_credential_names_in_every_url_attribute
    %w[http.url url.full].each do |key|
      scrubbed = scrub(key => "https://x.test/p?api_key=a&access_token=b&password=c&secret=d&signature=e&page=2")

      assert_equal "https://x.test/p?api_key=[REDACTED]&access_token=[REDACTED]&password=[REDACTED]" \
                   "&secret=[REDACTED]&signature=[REDACTED]&page=2", scrubbed[key]
    end
  end

  def test_url_query_has_no_question_mark
    assert_equal "token=[REDACTED]&page=2", scrub("url.query" => "token=abc&page=2")["url.query"]
  end

  def test_a_parameter_that_only_contains_a_credential_word_is_left_alone
    target = "/colors?monkey=1&keyword=blue&tokenizer=x"

    assert_equal target, scrub("http.target" => target)["http.target"]
  end

  def test_a_url_with_no_query_string_is_untouched
    assert_equal "/colors/new_arrivals", scrub("http.target" => "/colors/new_arrivals")["http.target"]
  end

  def test_request_and_response_headers_are_dropped
    scrubbed = scrub("http.request.header.authorization" => "Bearer abc",
                     "http.response.header.set_cookie" => "session=1", "http.method" => "GET")

    assert_equal({ "http.method" => "GET" }, scrubbed)
  end

  def test_attributes_needing_no_change_come_back_as_the_same_object
    attributes = { "http.method" => "GET", "db.statement" => "SELECT * FROM colors WHERE id = $?" }

    assert_same attributes, scrub(attributes)
    assert_nil scrub(nil)
  end

  def test_a_credential_in_free_text_is_redacted
    body = "GET url=https://api.scrapfly.io/scrape?key=scp-live-57b04a&asp=false"

    assert_equal "GET url=https://api.scrapfly.io/scrape?key=[REDACTED]&asp=false", Scrubber.scrub_text(body)
  end

  def test_the_usual_credential_names_in_free_text
    scrubbed = Scrubber.scrub_text("a token=abc b api_key=def c password=ghi d access_token=jkl e signature=mno")

    %w[abc def ghi jkl mno].each { |secret| refute_includes scrubbed, secret }
  end

  def test_a_bearer_value_is_redacted
    assert_equal "Authorization: Bearer [REDACTED]", Scrubber.scrub_text("Authorization: Bearer sk-abc123XYZ")
  end

  def test_ordinary_text_and_non_strings_pass
    body = "Inventory run=42 finished. items=875 errors=3 monkey=1 keyword=blue"

    assert_equal body, Scrubber.scrub_text(body)
    assert_nil Scrubber.scrub_text(nil)
    assert_equal 42, Scrubber.scrub_text(42)
  end

  def test_a_credential_in_a_span_never_reaches_the_exporter_behind
    recording = RecordingExporter.new
    provider = OpenTelemetry::SDK::Trace::TracerProvider.new
    provider.add_span_processor(OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(Packrat::Otel::ScrubbingSpanExporter.new(recording)))

    provider.tracer("test").in_span("GET /scrape") do |span|
      span.set_attribute("http.target", "/scrape?key=scp-live-abc123&asp=false")
      span.set_attribute("http.request.header.authorization", "Bearer scp-live-abc123")
    end
    provider.tracer("test").in_span("GET /colors") { |span| span.set_attribute("http.status_code", 200) }

    scraped, colors = recording.batches.flatten
    assert_equal({ "http.target" => "/scrape?key=[REDACTED]&asp=false" }, scraped.attributes)
    assert_equal({ "http.status_code" => 200 }, colors.attributes)
  end

  def test_a_credential_in_a_log_line_never_reaches_the_exporter_behind
    recording = RecordingExporter.new
    provider = OpenTelemetry::SDK::Logs::LoggerProvider.new
    provider.add_log_record_processor(OpenTelemetry::SDK::Logs::Export::SimpleLogRecordProcessor.new(Packrat::Otel::ScrubbingLogExporter.new(recording)))

    logger = provider.logger(name: "test")
    logger.on_emit(body: "\e[1m\e[36mfetch\e[0m url=https://api.scrapfly.io/?key=s3cret", attributes: { "url.full" => "https://x.test/?token=t" })
    logger.on_emit(body: "plain line", attributes: { "a" => 1 })

    scraped, plain = recording.batches.flatten
    assert_equal "fetch url=https://api.scrapfly.io/?key=[REDACTED]", scraped.body
    assert_equal({ "url.full" => "https://x.test/?token=[REDACTED]" }, scraped.attributes)
    assert_equal "plain line", plain.body
  end

  def test_flush_and_shutdown_reach_the_exporter_behind
    recording = RecordingExporter.new
    exporter = Packrat::Otel::ScrubbingLogExporter.new(recording)

    exporter.force_flush
    exporter.shutdown

    assert_equal [ 1, 1 ], [ recording.flushes, recording.shutdowns ]
  end
end
