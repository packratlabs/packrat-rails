require "rails/railtie"

module Packrat
  class Railtie < Rails::Railtie
    initializer "packrat.middleware" do |app|
      Packrat.guard("middleware") do
        app.config.middleware.insert_before(0, RackSpan) if Packrat.config.allowed? && !Otel.datadog?
      end
      Packrat.guard("browser events") do
        app.config.middleware.use(Browser) if Packrat.config.allowed?
      end
    end

    # Registered when the gem is required, so a controller defined before boot ends has the macros too.
    ActiveSupport.on_load(:action_controller) do
      Packrat.guard("browser events") { include Packrat::Browser::Controller }
    end

    # The decision must come after every after_initialize block, so that an app that configures
    # OpenTelemetry late has done so. to_prepare runs after config/initializers registered theirs, so
    # a block registered here is the last. An initializer declared after: :finisher_hook is not the
    # same thing: the sort pulls the whole Finisher ahead of config/initializers. to_prepare runs
    # again on every reload in development, hence the flag.
    config.to_prepare do
      next if Packrat.registered

      Packrat.registered = true
      Rails.application.config.after_initialize { Packrat.guard("boot") { Packrat.start } }
    end
  end
end
