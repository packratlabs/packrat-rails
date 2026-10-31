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

  def scrub(attributes) = Scrubber.new.scrub_attributes(attributes)

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

    assert_equal "GET url=https://api.scrapfly.io/scrape?key=[REDACTED]&asp=false", Scrubber.new.scrub_text(body)
  end

  def test_the_usual_credential_names_in_free_text
    scrubbed = Scrubber.new.scrub_text("a token=abc b api_key=def c password=ghi d access_token=jkl e signature=mno")

    %w[abc def ghi jkl mno].each { |secret| refute_includes scrubbed, secret }
  end

  def test_a_bearer_value_is_redacted
    assert_equal "Authorization: Bearer [REDACTED]", Scrubber.new.scrub_text("Authorization: Bearer sk-abc123XYZ")
  end

  def test_ordinary_text_and_non_strings_pass
    body = "Inventory run=42 finished. items=875 errors=3 monkey=1 keyword=blue"

    assert_equal body, Scrubber.new.scrub_text(body)
    assert_nil Scrubber.new.scrub_text(nil)
    assert_equal 42, Scrubber.new.scrub_text(42)
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

  def test_an_exception_the_instrumentation_records_is_scrubbed
    recording = RecordingExporter.new
    provider = OpenTelemetry::SDK::Trace::TracerProvider.new
    provider.add_span_processor(OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(Packrat::Otel::ScrubbingSpanExporter.new(recording, Scrubber.new(key: "k"))))

    provider.tracer("test").in_span("GET /scrape") do |span|
      span.record_exception(RuntimeError.new("fetch https://x.test/?token=s3cret for jane@example.com failed"))
    end

    attributes = recording.batches.flatten.first.events.first.attributes
    refute_match(/s3cret|jane@example\.com/, attributes["exception.message"])
    assert_match "token=[REDACTED]", attributes["exception.message"]
    assert_equal "RuntimeError", attributes["exception.type"]
  end

  def test_filter_parameters_redact_query_parameters
    scrubber = Scrubber.new(filters: [ :email, :t ])
    scrubbed = scrubber.scrub_attributes("url.query" => "t=eyJfcmFpbHMi&page=2&user%5Bemail%5D=x", "http.target" => "/in?t=abc")

    assert_equal "t=[REDACTED]&page=2&user%5Bemail%5D=[REDACTED]", scrubbed["url.query"]
    assert_equal "/in?t=[REDACTED]", scrubbed["http.target"]
  end

  def test_filter_parameters_redact_rails_error_context
    scrubber = Scrubber.new(filters: [ :passw ])
    scrubbed = scrubber.scrub_attributes("rails.error.context.password" => "hunter2", "rails.error.context.item_id" => "42")

    assert_equal({ "rails.error.context.password" => "[REDACTED]", "rails.error.context.item_id" => "42" }, scrubbed)
  end

  def test_an_email_becomes_a_token_keyed_by_the_ingest_key
    scrubber = Scrubber.new(key: "packrat_ingest_a")
    once = scrubber.scrub_text("Sent roundup email to user=Jane.Doe@gmail.com (212/431)")
    again = scrubber.scrub_text("Opened by jane.doe@gmail.com")

    token = once[/\[email:\h{8}\]/]
    refute_nil token
    assert_equal "Sent roundup email to user=#{token} (212/431)", once
    assert_includes again, token
    refute_includes Scrubber.new(key: "packrat_ingest_b").scrub_text("jane.doe@gmail.com"), token
  end

  def test_an_ipv4_address_keeps_its_network
    line = %(Started GET "/" for 203.0.113.77 at 2026-10-28 14:02:11 +0000)

    assert_equal %(Started GET "/" for 203.0.113.0 at 2026-10-28 14:02:11 +0000), Scrubber.new.scrub_text(line)
  end

  def test_numbers_that_only_look_like_an_ip_are_left_alone
    text = "Chrome/120.0.6099.109 v1.2.3 999.1.1.1 at 14:02:11 Foo::Bar"

    assert_equal text, Scrubber.new.scrub_text(text)
  end

  def test_an_ipv6_address_keeps_its_slash_48
    assert_equal "from 2001:db8:85a3:: done", Scrubber.new.scrub_text("from 2001:db8:85a3:8d3:1319:8a2e:370:7348 done")
    assert_equal "from 2001:db8:85a3:: done", Scrubber.new.scrub_text("from 2001:db8:85a3::8a2e:370:7334 done")
  end

  def test_personal_data_in_any_attribute_and_in_an_outbound_path
    scrubbed = Scrubber.new.scrub_attributes("http.target" => "/v3/subscribers/jane@example.com", "enduser.ip" => "198.51.100.23")

    assert_match(%r{\A/v3/subscribers/\[email:\h{8}\]\z}, scrubbed["http.target"])
    assert_equal "198.51.100.0", scrubbed["enduser.ip"]
  end

  def test_the_address_of_a_server_the_app_called_is_kept
    attributes = { "net.peer.ip" => "10.0.4.12", "server.address" => "10.0.4.13", "db.system" => "postgresql" }

    assert_same attributes, Scrubber.new.scrub_attributes(attributes)
  end

  def test_each_pattern_can_be_turned_off
    text = "jane@example.com from 203.0.113.77"

    assert_equal text, Scrubber.new(redact: []).scrub_text(text)
    assert_match "203.0.113.77", Scrubber.new(redact: %w[email]).scrub_text(text)
  end

  def test_a_structured_log_body_is_filtered_and_scrubbed
    recording = RecordingExporter.new
    exporter = Packrat::Otel::ScrubbingLogExporter.new(recording, Scrubber.new(filters: [ :passw ]))
    provider = OpenTelemetry::SDK::Logs::LoggerProvider.new
    provider.add_log_record_processor(OpenTelemetry::SDK::Logs::Export::SimpleLogRecordProcessor.new(exporter))

    provider.logger(name: "test").on_emit(body: { "user" => "jane@example.com", "password" => "hunter2", "tries" => 3 })

    body = recording.batches.flatten.first.body
    assert_match(/\A\[email:\h{8}\]\z/, body["user"])
    assert_equal "[REDACTED]", body["password"]
    assert_equal 3, body["tries"]
  end

  def test_strict_sends_no_log_text
    recording = RecordingExporter.new
    exporter = Packrat::Otel::ScrubbingLogExporter.new(recording, Scrubber.new(strict: true))
    provider = OpenTelemetry::SDK::Logs::LoggerProvider.new
    provider.add_log_record_processor(OpenTelemetry::SDK::Logs::Export::SimpleLogRecordProcessor.new(exporter))

    provider.logger(name: "test").on_emit(body: "Support ticket 88: my card was declined", severity_text: "INFO")

    record = recording.batches.flatten.first
    assert_equal "[REDACTED]", record.body
    assert_equal "INFO", record.severity_text
  end

  def test_strict_keeps_the_path_and_drops_query_strings_user_agents_and_context
    scrubbed = Scrubber.new(strict: true).scrub_attributes(
      "http.target" => "/tickets/88?q=refund", "url.full" => "https://x.test/a?b=c", "url.query" => "q=refund",
      "user_agent.original" => "Mozilla/5.0", "rails.error.context.ticket" => "my card was declined", "http.route" => "/tickets/:id"
    )

    assert_equal({ "http.target" => "/tickets/88", "url.full" => "https://x.test/a", "http.route" => "/tickets/:id" }, scrubbed)
  end

  def test_strict_keeps_an_exceptions_class_and_frames_without_its_message
    error = begin
      raise ArgumentError, "no mailbox for jane@example.com"
    rescue ArgumentError => raised
      raised
    end
    attributes = { "exception.type" => "ArgumentError", "exception.message" => error.message,
                   "exception.stacktrace" => error.full_message(highlight: false, order: :top) }

    scrubbed = Scrubber.new(strict: true).scrub_event_attributes(attributes)

    assert_equal "[REDACTED]", scrubbed["exception.message"]
    assert_equal "ArgumentError", scrubbed["exception.type"]
    refute_includes scrubbed["exception.stacktrace"], "mailbox"
    assert_includes scrubbed["exception.stacktrace"], "scrubber_test.rb"
  end

  def test_rails_error_context_hashes_are_filtered_before_they_become_json
    provider = OpenTelemetry::SDK::Trace::TracerProvider.new
    recording = RecordingExporter.new
    provider.add_span_processor(OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(recording))
    OpenTelemetry.tracer_provider = provider

    Packrat::Otel::ErrorSpans.new(Scrubber.new(filters: [ :passw ]))
      .report(RuntimeError.new("boom"), handled: true, severity: :error, context: { params: { "password" => "hunter2", "page" => "2" } })

    context = recording.batches.flatten.first.events.first.attributes["rails.error.context.params"]
    assert_equal({ "password" => "[REDACTED]", "page" => "2" }, JSON.parse(context))
  end

  def test_flush_and_shutdown_reach_the_exporter_behind
    recording = RecordingExporter.new
    exporter = Packrat::Otel::ScrubbingLogExporter.new(recording)

    exporter.force_flush
    exporter.shutdown

    assert_equal [ 1, 1 ], [ recording.flushes, recording.shutdowns ]
  end
end
