require "logger"
require "opentelemetry/sdk"
require "opentelemetry/exporter/otlp"
require_relative "packrat/version"
require_relative "packrat/config"
require_relative "packrat/otel/scrubber"
require_relative "packrat/otel/error_spans"
require_relative "packrat/otel/root_kind_sampler"
require_relative "packrat/otel"
require_relative "packrat/rack_span"
require_relative "packrat/railtie" if defined?(Rails::Railtie)

module Packrat
  class << self
    attr_reader :setup
    attr_accessor :registered

    def config
      @config ||= Config.new(
        env: ENV, rails_env: Rails.env, app_name: Rails.application.class.module_parent_name.underscore
      )
    end

    # Packrat.configure { |config| config.ingest_key = "..." }, from config/initializers/packrat.rb.
    def configure
      yield config
    end

    # An app adds to what the gem configured with ActiveSupport.on_load(:packrat) { |setup| ... }.
    def start
      @setup = Otel::Setup.new(
        config:, logger: Rails.logger, errors: Rails.error, filters: Rails.application.config.filter_parameters
      ).call
      ActiveSupport.run_load_hooks(:packrat, @setup)
    end

    # The outermost catch: whatever goes wrong, the app boots without Packrat.
    def guard(name)
      yield
    rescue StandardError, LoadError => error
      key = (config.key rescue nil)
      Rails.logger&.warn("Packrat: #{name} failed (#{error.class}: #{redact(error.message, key)}); the app runs without it")
      nil
    end

    def redact(text, key)
      key ? text.to_s.gsub(key, Config::REDACTED) : text.to_s
    end
  end
end
