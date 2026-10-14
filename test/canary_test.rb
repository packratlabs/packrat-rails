require "test_helper"

# Every string the gem can produce, on every path, against a key that must appear in none of them.
class CanaryTest < PackratTest
  def test_the_key_is_never_printed
    strings = []
    collect = ->(setup) { strings.push(setup.line.to_s, *setup.warnings, setup.inspect, setup.to_s) }

    collect.(run_setup(config))
    teardown
    setup

    sdk_provider
    collect.(run_setup(config))
    setup

    sdk_provider
    collect.(run_setup(config({ "OTEL_EXPORTER_OTLP_ENDPOINT" => URL })))
    setup

    Object.const_set(:Datadog, Module.new { def self.configuration = nil })
    collect.(run_setup(config))
    Object.send(:remove_const, :Datadog)
    setup

    %i[load_logs span_processor log_record_processor configure_sdk use_sampler install].each do |method|
      collect.(run_setup(config) { |subject| subject.define_singleton_method(method) { |*| raise "broken #{CANARY}" } })
      teardown
      setup
    end

    config = config({ "OTEL_RESOURCE_ATTRIBUTES" => "service.name=api" })
    strings.push(config.inspect, config.to_s, config.service_name, config.environment, config.url, *config.resource_attributes.values)
    strings.push(log, @otel_log.string)

    assert(strings.none? { |string| string.include?(CANARY) }, strings.grep(/CANARY/).first)
  end

  def test_the_key_is_in_the_exporter_header
    run_setup(config)

    assert_equal CANARY, exporters(OpenTelemetry.tracer_provider).sole.instance_variable_get(:@headers)["Authorization"]
  end

  def test_guard_redacts
    # Minitest's Rails plugin defines a bare Rails module, with no logger.
    rails = defined?(::Rails) ? ::Rails : Object.const_set(:Rails, Module.new)
    logger = @logger
    rails.define_singleton_method(:logger) { logger }
    Packrat.instance_variable_set(:@config, config)

    assert_nil Packrat.guard("boot") { raise LoadError, "cannot load #{CANARY}" }
    assert_match "Packrat: boot failed (LoadError: cannot load [redacted]); the app runs without it", log
    refute_includes log, CANARY
  ensure
    Packrat.instance_variable_set(:@config, nil)
    rails.singleton_class.remove_method(:logger)
  end
end
