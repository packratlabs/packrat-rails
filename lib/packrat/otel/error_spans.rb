require "json"

module Packrat
  module Otel
    # Everything Rails.error hears -- an error that escapes a request or a job, one the app rescues and
    # reports itself, one in a runner script -- recorded on the span it happened in, or on a span of its
    # own when there is none.
    class ErrorSpans
      NAME = "Rails.error"
      # Rails puts the live controller and job objects in the context.
      SKIPPED_KEYS = %i[controller job].freeze
      # Rails reports these after the request or job instrumentation has recorded the same error.
      INSTRUMENTED_SOURCES = %w[application.action_dispatch job.sidekiq].freeze
      # A cache failure falls back to the source of truth; Sentry skips these too.
      CACHE_STORE_SOURCE = /_cache_store\.active_support\z/

      def initialize(scrubber = Scrubber.new)
        @scrubber = scrubber
      end

      # Scrubbed here as well as on export: with an app's own OpenTelemetry, its exporter receives
      # these events too.
      def report(error, handled:, severity:, context:, source: nil)
        return if skipped?(handled, source)

        exception = error.is_a?(Exception) ? error : RuntimeError.new(error.to_s)
        attributes = @scrubber.scrub_event_attributes(
          exception_attributes(exception, handled, severity, source).merge(context_attributes(context))
        )
        span = OpenTelemetry::Trace.current_span
        return span.record_exception(exception, attributes:) if span.recording?

        span = OpenTelemetry.tracer_provider.tracer("rails.error").start_root_span(NAME)
        span.record_exception(exception, attributes:)
        span.finish
      rescue StandardError => error
        OpenTelemetry.handle_error(exception: error, message: "Packrat::Otel::ErrorSpans#report failed")
      end

      private

      def skipped?(handled, source)
        (!handled && INSTRUMENTED_SOURCES.include?(source)) || CACHE_STORE_SOURCE.match?(source.to_s)
      end

      def exception_attributes(exception, handled, severity, source)
        {
          "exception.message" => utf8(exception.message),
          "exception.stacktrace" => utf8(exception.full_message(highlight: false, order: :top)),
          "exception.handled" => handled,
          "rails.error.severity" => severity.to_s,
          "rails.error.source" => source
        }.compact
      end

      def context_attributes(context)
        values = context.except(*SKIPPED_KEYS, :tags)
        values = values.merge(context[:tags]) if context[:tags].is_a?(Hash)

        values.each_with_object({}) do |(key, value), attributes|
          attributes["rails.error.context.#{key}"] = attribute_value(value) unless value.nil?
        end
      end

      def attribute_value(value)
        case value
        when Integer, Float, true, false then value
        when Hash then utf8(@scrubber.filter_hash(value).to_json)
        when Array then utf8(value.to_json)
        else utf8(value.to_s)
        end
      end

      def utf8(text)
        text.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "�")
      end
    end
  end
end
