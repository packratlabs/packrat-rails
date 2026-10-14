require "cgi"

module Packrat
  module Otel
    # Removes credentials before telemetry leaves the process. Packrat archives raw data and never
    # rewrites it, so anything that survives here is kept for good.
    #
    # Query strings are kept on purpose: they carry what a request was about, which is most of what
    # a trace is read for. Only the values of credential-named parameters are replaced.
    module Scrubber
      REDACTED = "[REDACTED]".freeze
      URL_KEYS = %w[http.target http.url url.full url.query].freeze
      HEADER_PREFIXES = %w[http.request.header. http.response.header.].freeze
      # A whole parameter name, or one segment of a snake_case name: api_key and access_token match,
      # keyword and monkey do not.
      CREDENTIAL_PARAM = /\A(?:[a-z0-9]+_)*(?:key|token|password|passwd|secret|signature|sig|auth|credential)(?:_[a-z0-9]+)*\z/i
      # Free text is redacted by pattern: log lines and error messages interpolate URLs, which is
      # where a credential usually appears.
      CREDENTIAL_IN_TEXT = /
        (?<name>\b(?:[a-z0-9]+_)?(?:api_key|access_token|key|token|password|passwd|secret|signature|sig|auth|credential)\s*=\s*)
        (?<value>[^\s&"'<>\]]+)
      /ix
      BEARER = %r{\b(?<scheme>Bearer|Basic)\s+(?<value>[A-Za-z0-9._~+/-]+=*)}i
      ANSI = /\e\[[0-9;]*m/

      class << self
        def scrub_text(text)
          return text unless text.is_a?(String)

          text.gsub(CREDENTIAL_IN_TEXT) { "#{Regexp.last_match(:name)}#{REDACTED}" }
              .gsub(BEARER) { "#{Regexp.last_match(:scheme)} #{REDACTED}" }
        end

        # The same hash when nothing needs to change, so callers can tell by identity.
        def scrub_attributes(attributes)
          return attributes if attributes.nil?
          return attributes unless attributes.any? { |key, value| header?(key) || redactable_url?(key, value) }

          attributes.each_with_object({}) do |(key, value), scrubbed|
            next if header?(key)

            scrubbed[key] = URL_KEYS.include?(key) ? redact_query(value) : value
          end
        end

        # SpanData and LogRecordData are frozen structs, so a changed one is rebuilt from its fields.
        def scrub_spans(spans)
          spans.map do |span|
            attributes = scrub_attributes(span.attributes)
            attributes.equal?(span.attributes) ? span : span.class.new(*span.to_h.merge(attributes:).values)
          end
        end

        def scrub_log_records(records)
          records.map do |record|
            attributes = scrub_attributes(record.attributes)
            body = record.body.is_a?(String) ? scrub_text(record.body.gsub(ANSI, "")) : record.body
            next record if attributes.equal?(record.attributes) && body == record.body

            record.class.new(*record.to_h.merge(attributes:, body:).values)
          end
        end

        private

        def header?(key)
          HEADER_PREFIXES.any? { |prefix| key.to_s.start_with?(prefix) }
        end

        def redactable_url?(key, value)
          URL_KEYS.include?(key) && value.to_s.include?("=")
        end

        def redact_query(url)
          head, separator, query = url.to_s.include?("?") ? url.to_s.partition("?") : [ "", "", url.to_s ]
          return url if query.empty?

          redacted = query.split("&").map do |pair|
            name, equals, _value = pair.partition("=")
            equals.empty? || !CREDENTIAL_PARAM.match?(CGI.unescape(name)) ? pair : "#{name}=#{REDACTED}"
          end
          "#{head}#{separator}#{redacted.join('&')}"
        end
      end
    end

    class ScrubbingSpanExporter
      def initialize(exporter)
        @exporter = exporter
      end

      def export(spans, timeout: nil)
        @exporter.export(Scrubber.scrub_spans(spans), timeout:)
      end

      def force_flush(timeout: nil)
        @exporter.force_flush(timeout:)
      end

      def shutdown(timeout: nil)
        @exporter.shutdown(timeout:)
      end
    end

    class ScrubbingLogExporter < ScrubbingSpanExporter
      def export(records, timeout: nil)
        @exporter.export(Scrubber.scrub_log_records(records), timeout:)
      end
    end
  end
end
