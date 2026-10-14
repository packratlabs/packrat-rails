module Packrat
  # The Rack instrumentation is middleware, and the stack is built before the end of boot, where
  # Packrat decides whether it configures OpenTelemetry at all. So the Railtie puts this in early,
  # and it becomes the Rack span or passes every request straight through once that is decided.
  class RackSpan
    def initialize(app)
      @app = app
      @lock = Mutex.new
    end

    def call(env)
      (@inner || inner).call(env)
    end

    private

    def inner
      return @app unless Packrat.setup

      @lock.synchronize { @inner ||= Packrat.setup.rack(@app) }
    end
  end
end
