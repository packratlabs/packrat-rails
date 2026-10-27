# Boots a Rails app with Packrat in this process and prints what the boot test asserts on.
require "tmpdir"
require "json"
require "action_controller/railtie"
require "action_view/railtie"
require "packrat-rails"

ENV["PACKRAT_INGEST_KEY"] = "packrat_ingest_boot"
ENV["PACKRAT_INGEST_URL"] = "http://127.0.0.1:9"

root = Dir.mktmpdir
FileUtils.mkdir_p("#{root}/app/views/pages")
File.write("#{root}/app/views/pages/show.html.erb", "<%= render 'outer' %>")
File.write("#{root}/app/views/pages/_outer.html.erb", "<%= render 'inner' %>")
File.write("#{root}/app/views/pages/_inner.html.erb", "inner")

module Shop
  class App < Rails::Application
    config.eager_load = false
    config.logger = Logger.new(nil)
    config.secret_key_base = "x" * 64
    config.hosts.clear
    routes.append { get "/" => "pages#show" }
  end
end
Shop::App.config.root = root

class PagesController < ActionController::Base
  def show = render(:show)
end

Shop::App.initialize!

exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
OpenTelemetry.tracer_provider.add_span_processor(OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter))
errors = []
OpenTelemetry.error_handler = ->(exception: nil, message: nil) { errors << (exception&.message || message) }

2.times { Rack::MockRequest.new(Shop::App).get("/") }

subscribers = ActiveSupport::Notifications.notifier.instance_variable_get(:@string_subscribers)
puts JSON.generate(
  outcome: Packrat.setup.outcome,
  subscribers: %w[render_template render_partial render_collection render_layout].map { |name| "#{name}.action_view" }.to_h { |event|
    [ event, subscribers[event].count { |subscriber| subscriber.instance_variable_get(:@delegate).is_a?(OpenTelemetry::Instrumentation::ActiveSupport::SpanSubscriber) } ]
  },
  context_depth: OpenTelemetry::Context.send(:stack).size,
  errors: errors,
  roots: exporter.finished_spans.select { |span| span.parent_span_id == OpenTelemetry::Trace::INVALID_SPAN_ID }.map(&:name),
  render_spans: exporter.finished_spans.count { |span| span.name.end_with?(".action_view") }
)
