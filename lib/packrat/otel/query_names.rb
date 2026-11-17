require "active_support/isolated_execution_state"
require "active_support/notifications"

module Packrat
  module Otel
    # One span per query, in place of the Active Record instrumentation's span around the driver's.
    # Rails names each query in the sql.active_record event its log line prints ("Order Load",
    # "Order Create"), and the driver's span starts inside that event, so the driver's span takes the
    # name and keeps its SQL. A query Rails did not name keeps the driver's name.
    class QueryNames < OpenTelemetry::SDK::Trace::SpanProcessor
      EVENT = "sql.active_record".freeze
      SCOPES = %w[OpenTelemetry::Instrumentation::PG OpenTelemetry::Instrumentation::Mysql2 OpenTelemetry::Instrumentation::Trilogy].freeze
      KEY = :packrat_query_names

      # The sql.active_record subscriber: the name of each query in flight, innermost last.
      class Names
        def start(_event, _id, payload)
          name = payload[:name]
          Names.stack << (name unless name.nil? || name.empty?)
        end

        def finish(_event, _id, _payload)
          Names.stack.pop
        end

        def self.stack
          ActiveSupport::IsolatedExecutionState[KEY] ||= []
        end
      end

      def self.install(provider)
        ActiveSupport::Notifications.subscribe(EVENT, Names.new)
        provider.add_span_processor(new)
      end

      def on_start(span, _parent_context)
        return unless SCOPES.include?(span.instrumentation_scope&.name)

        name = Names.stack.last
        span.name = name if name
      end
    end
  end
end
