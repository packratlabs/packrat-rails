# Run by corpus/boot.rb inside the app, through `bin/rails runner`. Prints what the gem did as one
# JSON line, then makes the log line and the error the listener must receive.
require "json"

provider = OpenTelemetry.tracer_provider
processors = Array(provider.instance_variable_get(:@span_processors)).map do |processor|
  exporter = processor.instance_variable_get(:@exporter)
  exporter = exporter.instance_variable_get(:@exporter) if exporter.is_a?(Packrat::Otel::ScrubbingSpanExporter)
  { processor: processor.class.name, exporter: exporter&.class&.name, uri: exporter&.instance_variable_get(:@uri)&.to_s }
end
order = Rails.application.initializers.tsort_each.map { |initializer| initializer.name.to_s }
hooks = ActiveSupport.instance_variable_get(:@load_hooks)[:after_initialize].map { |hook, _| hook.source_location.join(":") }
instrumentation = OpenTelemetry::Instrumentation.registry.instance_variable_get(:@instrumentation)
  .map(&:instance).select(&:installed?).map(&:name)

puts "PACKRAT_BOOT " + JSON.generate(
  outcome: Packrat.setup&.outcome, line: Packrat.setup&.line, warnings: Packrat.setup&.warnings,
  provider: provider.class.name, processors:,
  logger_provider: (OpenTelemetry.logger_provider.class.name if OpenTelemetry.respond_to?(:logger_provider)),
  order:, after_initialize: hooks,
  middleware: Rails.application.middleware.map { |middleware| middleware.klass.to_s.sub(/:0x\h+/, "") },
  instrumentation:, error_subscribers: Rails.error.instance_variable_get(:@subscribers).map { |subscriber| subscriber.class.name }
)

Rails.logger.info("hello token=boot-secret")
raise "boom" rescue Rails.error.report($!)

# One request through the whole middleware stack, and one the Rack instrumentation must leave out. The
# Rack span ends when the server closes the body.
require "rack/mock"
[ "/hello", "/up" ].each { |path| Rails.application.call(Rack::MockRequest.env_for("http://localhost#{path}", "HTTP_HOST" => "localhost"))[2].then { |body| body.close if body.respond_to?(:close) } }
