require_relative "lib/packrat/version"

Gem::Specification.new do |spec|
  spec.name = "packrat-rails"
  spec.version = Packrat::VERSION
  spec.authors = [ "Packrat Labs" ]
  spec.summary = "OpenTelemetry for Rails, configured to send to Packrat with one key"
  spec.homepage = "https://packrat.sh/docs/ruby-on-rails"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1"
  spec.metadata["source_code_uri"] = "https://github.com/packratlabs/packrat-rails"

  spec.files = Dir["lib/**/*.rb", "README.md", "LICENSE"]

  spec.add_dependency "railties", ">= 7.1"
  spec.add_dependency "opentelemetry-sdk", ">= 1.2"
  spec.add_dependency "opentelemetry-exporter-otlp", ">= 0.26"
  spec.add_dependency "opentelemetry-logs-sdk", ">= 0.1"
  spec.add_dependency "opentelemetry-exporter-otlp-logs", ">= 0.1"
  spec.add_dependency "opentelemetry-instrumentation-rack", ">= 0.24"
  spec.add_dependency "opentelemetry-instrumentation-action_pack", ">= 0.9"
  spec.add_dependency "opentelemetry-instrumentation-active_job", ">= 0.7"
  spec.add_dependency "opentelemetry-instrumentation-active_record", ">= 0.7"
  spec.add_dependency "opentelemetry-instrumentation-net_http", ">= 0.22"
  spec.add_dependency "opentelemetry-instrumentation-pg", ">= 0.27"
  spec.add_dependency "opentelemetry-instrumentation-mysql2", ">= 0.27"
  spec.add_dependency "opentelemetry-instrumentation-logger", ">= 0.1"
end
