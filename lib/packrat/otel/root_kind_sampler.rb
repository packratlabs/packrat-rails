module Packrat
  module Otel
    # A trace that starts with a request (server) or a job (consumer) is work. One that starts with
    # anything else is a poll: Solid Queue and Solid Cable each ask Postgres for work about ten times
    # a second, and every poll would otherwise be a trace of its own. Children never reach this class;
    # parent_based routes only roots here, and a child follows its root. A Rake task is work too,
    # though its span is internal; when Rails boots inside the task, the root is its execute.
    class RootKindSampler
      KEEP = %i[server consumer].freeze
      NAMES = [ ErrorSpans::NAME, "rake.invoke", "rake.execute" ].freeze

      def should_sample?(trace_id:, parent_context:, links:, name:, kind:, attributes:)
        keep = KEEP.include?(kind) || NAMES.include?(name)
        decision = keep ? OpenTelemetry::SDK::Trace::Samplers::Decision::RECORD_AND_SAMPLE
                        : OpenTelemetry::SDK::Trace::Samplers::Decision::DROP
        tracestate = OpenTelemetry::Trace.current_span(parent_context).context.tracestate
        OpenTelemetry::SDK::Trace::Samplers::Result.new(decision:, tracestate:)
      end

      def description
        "RootKindSampler{#{KEEP.join(',')}}"
      end
    end
  end
end
