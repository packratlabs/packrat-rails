module Packrat
  module Otel
    # Caps the spans one trace keeps in this process. A root that lives as long as the process (a
    # server started from a Rake task, a job that loops forever) would otherwise keep every poll under
    # it. parent_based routes only children of a sampled local parent here; a dropped span's children
    # follow it. The sampler never learns when a trace ends, so it forgets the oldest past TRACES.
    class TraceBudget
      SPANS = 5_000
      TRACES = 10_000

      def initialize(spans: SPANS, traces: TRACES)
        @spans = spans
        @traces = traces
        @counts = {}
        @mutex = Mutex.new
      end

      def should_sample?(trace_id:, parent_context:, links:, name:, kind:, attributes:)
        count = @mutex.synchronize do
          @counts.shift if @counts.size >= @traces && !@counts.key?(trace_id)
          @counts[trace_id] = @counts.fetch(trace_id, 0) + 1
        end
        decision = count <= @spans ? OpenTelemetry::SDK::Trace::Samplers::Decision::RECORD_AND_SAMPLE
                                   : OpenTelemetry::SDK::Trace::Samplers::Decision::DROP
        tracestate = OpenTelemetry::Trace.current_span(parent_context).context.tracestate
        OpenTelemetry::SDK::Trace::Samplers::Result.new(decision:, tracestate:)
      end

      def description
        "TraceBudget{#{@spans}}"
      end
    end
  end
end
