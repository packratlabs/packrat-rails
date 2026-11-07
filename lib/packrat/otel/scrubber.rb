require "cgi"
require "ipaddr"
require "json"
require "openssl"
require "active_support/parameter_filter"

module Packrat
  module Otel
    # Removes credentials and personal data before telemetry leaves the process. Packrat archives raw
    # data and never rewrites it, so anything that survives here is kept for good.
    #
    # Query strings are kept on purpose unless privacy is strict: they carry what a request was about,
    # which is most of what a trace is read for. Only the values of credential-named parameters, and of
    # those the app's filter_parameters names, are replaced.
    class Scrubber
      REDACTED = "[REDACTED]".freeze
      URL_KEYS = %w[http.target http.url url.full url.query].freeze
      TEXT_KEYS = %w[exception.message exception.stacktrace].freeze
      HEADER_PREFIXES = %w[http.request.header. http.response.header.].freeze
      CONTEXT_PREFIX = "rails.error.context.".freeze
      # The address of a server the app called, not of a person.
      PEER_KEYS = %w[net.peer.ip net.peer.name network.peer.address server.address server.socket.address net.sock.peer.addr].freeze
      STRICT_DROPPED_KEYS = %w[url.query http.user_agent user_agent.original].freeze
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
      EMAIL = /[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}/
      OCTET = /(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)/
      # Not part of a longer dotted number, so a version such as 120.0.6099.109 is left alone.
      IPV4 = /(?<![\d.])(#{OCTET}\.#{OCTET}\.#{OCTET})\.#{OCTET}(?!\.?\d)/
      IPV6 = /(?<![\w:])(?:[0-9a-f]{0,4}:){2,7}[0-9a-f]{0,4}(?![\w:])/i

      # keys, patterns and redactor are the app's own (config.redact_keys, redact_patterns, redact).
      def initialize(key: nil, filters: [], redact: Config::REDACTIONS, strict: false, keys: [], patterns: [], redactor: nil)
        @key = key.to_s
        # A filter_parameters string matches any name that contains it; a key the app names matches whole.
        filters = filters + keys.map { |name| /\A#{Regexp.escape(name)}\z/i }
        @filter = ActiveSupport::ParameterFilter.new(filters, mask: REDACTED) unless filters.empty?
        @keys = keys.map(&:downcase)
        @patterns = patterns
        @redactor = redactor
        @email = redact.include?("email")
        @ip = redact.include?("ip")
        @strict = strict
      end

      # The ingest key is the HMAC key, and is never printed.
      def inspect
        "#<#{self.class.name} email=#{@email} ip=#{@ip} strict=#{@strict} filters=#{!@filter.nil?} " \
          "keys=#{@keys.size} patterns=#{@patterns.size} redactor=#{!@redactor.nil?}>"
      end
      alias to_s inspect

      # A log body, an exception message or a stack.
      def scrub_text(text)
        return text unless text.is_a?(String)

        text = text.gsub(CREDENTIAL_IN_TEXT) { "#{Regexp.last_match(:name)}#{REDACTED}" } if text.include?("=")
        redact_values(text.gsub(BEARER) { "#{Regexp.last_match(:scheme)} #{REDACTED}" })
      end

      # The same hash when nothing needs to change, so callers can tell by identity.
      def scrub_attributes(attributes)
        return attributes if attributes.nil? || attributes.empty?

        scrubbed = attributes.each_with_object({}) do |(key, value), kept|
          kept[key] = scrub_value(key.to_s, value) unless dropped?(key.to_s)
        end
        scrubbed == attributes ? attributes : scrubbed
      end

      # Strict keeps an exception's class and frames, and takes its message out of the stack as well.
      def scrub_event_attributes(attributes)
        message = attributes&.fetch("exception.message", nil)
        return scrub_attributes(attributes) unless @strict && message.is_a?(String) && !message.empty?

        stack = attributes["exception.stacktrace"]
        stack = stack.gsub(message, REDACTED) if stack.is_a?(String)
        scrub_attributes(attributes.merge("exception.message" => REDACTED, "exception.stacktrace" => stack).compact)
      end

      # A hash an app hands over whole, such as Rails.error's context, filtered as its logs would be.
      def filter_hash(hash)
        @filter ? @filter.filter(hash) : hash
      end

      # SpanData, Event and LogRecordData are frozen structs, so a changed one is rebuilt from its fields.
      def scrub_spans(spans)
        spans.map do |span|
          attributes = scrub_attributes(span.attributes)
          events = scrub_events(span.events)
          next span if attributes.equal?(span.attributes) && events.equal?(span.events)

          span.class.new(*span.to_h.merge(attributes:, events:).values)
        end
      end

      def scrub_log_records(records)
        records.map do |record|
          attributes = scrub_attributes(record.attributes)
          body = scrub_body(record.body)
          next record if attributes.equal?(record.attributes) && body == record.body

          record.class.new(*record.to_h.merge(attributes:, body:).values)
        end
      end

      private

      def scrub_events(events)
        return events if events.nil? || events.empty?

        scrubbed = events.map do |event|
          attributes = scrub_event_attributes(event.attributes)
          attributes.equal?(event.attributes) ? event : event.class.new(*event.to_h.merge(attributes:).values)
        end
        scrubbed.zip(events).all? { |new, old| new.equal?(old) } ? events : scrubbed
      end

      def scrub_body(body)
        case body
        when String then @strict ? REDACTED : custom(scrub_text(body.gsub(ANSI, "")), nil)
        when Hash then filter_hash(body).transform_values { |value| scrub_body(value) }
        when Array then body.map { |value| scrub_body(value) }
        else body
        end
      end

      # Fails closed: a value the app's block cannot answer for is not sent.
      def custom(value, name)
        return value unless @redactor && value.is_a?(String)

        result = @redactor.call(value, name)
        result.is_a?(String) ? result : REDACTED
      rescue StandardError => error
        unless @redactor_failed
          @redactor_failed = true
          OpenTelemetry.handle_error(exception: error, message: "Packrat: the config.redact block raised, so the values it was given are sent as #{REDACTED}")
        end
        REDACTED
      end

      def dropped?(key)
        HEADER_PREFIXES.any? { |prefix| key.start_with?(prefix) } ||
          (@strict && (STRICT_DROPPED_KEYS.include?(key) || key.start_with?(CONTEXT_PREFIX)))
      end

      def scrub_value(key, value)
        return value.map { |item| scrub_value(key, item) } if value.is_a?(Array)
        return value unless value.is_a?(String)
        return REDACTED if redacted_key?(key)

        custom(builtin(key, value), key)
      end

      def builtin(key, value)
        if URL_KEYS.include?(key) then redact_values(@strict ? value.split("?", 2).first : redact_query(value))
        elsif TEXT_KEYS.include?(key) then scrub_text(value)
        elsif key.start_with?(CONTEXT_PREFIX) then filtered?(key.delete_prefix(CONTEXT_PREFIX)) ? REDACTED : scrub_text(value)
        elsif PEER_KEYS.include?(key) then value
        else redact_values(value)
        end
      end

      # The whole name, or its last dotted segment: ssn matches ssn and enduser.ssn.
      def redacted_key?(key)
        return false if @keys.empty?

        name = key.downcase
        @keys.include?(name) || @keys.include?(name.rpartition(".").last)
      end

      def redact_values(text)
        @patterns.each { |pattern| text = text.gsub(pattern, REDACTED) }
        text = text.gsub(EMAIL) { "[email:#{digest(Regexp.last_match(0))}]" } if @email && text.include?("@")
        return text unless @ip

        text = text.gsub(IPV4) { "#{Regexp.last_match(1)}.0" } if text.match?(/\d\.\d/)
        text = text.gsub(IPV6) { |match| ipv6(match) } if text.include?("::") || text.count(":") >= 7
        text
      end

      # Keyed by the ingest key, so the same address is the same token within an app, and a list of
      # addresses cannot be hashed to find one.
      def digest(email)
        OpenSSL::HMAC.hexdigest("SHA256", @key, email.downcase)[0, 8]
      end

      # The /48 a network is usually given, as /24 is for IPv4. A clock time has colons too, so only a
      # candidate IPAddr reads as IPv6 is masked.
      def ipv6(candidate)
        return candidate unless candidate.include?("::") || candidate.count(":") == 7

        address = IPAddr.new(candidate)
        address.ipv6? ? address.mask(48).to_s : candidate
      rescue IPAddr::Error
        candidate
      end

      def redact_query(url)
        return url unless url.include?("=")

        head, separator, query = url.include?("?") ? url.partition("?") : [ "", "", url ]
        return url if query.empty?

        redacted = query.split("&").map do |pair|
          name, equals, _value = pair.partition("=")
          unescaped = CGI.unescape(name)
          equals.empty? || !(CREDENTIAL_PARAM.match?(unescaped) || filtered?(unescaped)) ? pair : "#{name}=#{REDACTED}"
        end
        "#{head}#{separator}#{redacted.join('&')}"
      end

      def filtered?(name)
        !@filter.nil? && @filter.filter(name => "")[name] == REDACTED
      end
    end

    # With an io (PACKRAT_DEBUG_EXPORT), each item is also written there as one JSON line, exactly as
    # scrubbed. Not through a Logger: the logger instrumentation would export each line, and print it again.
    class ScrubbingSpanExporter
      PREFIX = "Packrat export: ".freeze

      def initialize(exporter, scrubber = Scrubber.new, io: nil)
        @exporter = exporter
        @scrubber = scrubber
        @io = io
      end

      def export(spans, timeout: nil)
        spans = @scrubber.scrub_spans(spans)
        write_lines(spans) { |span| span_line(span) }
        @exporter.export(spans, timeout:)
      end

      def force_flush(timeout: nil)
        @exporter.force_flush(timeout:)
      end

      def shutdown(timeout: nil)
        @exporter.shutdown(timeout:)
      end

      private

      def write_lines(items)
        return unless @io

        @io.write(items.map { |item| "#{PREFIX}#{JSON.generate(yield(item))}\n" }.join)
      rescue StandardError => error
        OpenTelemetry.handle_error(exception: error, message: "Packrat: PACKRAT_DEBUG_EXPORT could not print a batch")
      end

      def span_line(span)
        {
          span: span.name, kind: span.kind, trace_id: span.hex_trace_id, span_id: span.hex_span_id,
          attributes: span.attributes.to_h,
          events: Array(span.events).map { |event| { name: event.name, attributes: event.attributes.to_h } }
        }
      end
    end

    class ScrubbingLogExporter < ScrubbingSpanExporter
      def export(records, timeout: nil)
        records = @scrubber.scrub_log_records(records)
        write_lines(records) { |record| log_line(record) }
        @exporter.export(records, timeout:)
      end

      private

      def log_line(record)
        { log: record.body, severity: record.severity_text, attributes: record.attributes.to_h }
      end
    end
  end
end
