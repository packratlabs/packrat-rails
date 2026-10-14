require "test_helper"

class FailSoftTest < PackratTest
  CONFIGURE = {
    load_logs: "logs SDK", span_processor: "traces exporter", log_record_processor: "logs exporter",
    configure_sdk: "SDK", use_sampler: "sampler", install: "instrumentation rack"
  }.freeze

  [ StandardError, LoadError ].each do |kind|
    CONFIGURE.each do |method, step|
      define_method(:"test_configure_#{method}_#{kind.name.downcase}") do
        setup = run_setup(config) { |subject| fail_in(subject, method, kind) }

        assert_match "Packrat: #{step} failed (#{kind.name}: broken", log
        refute_includes log, CANARY
        refute_nil setup.line
      end
    end

    define_method(:"test_rails_error_#{kind.name.downcase}") do
      @errors.define_singleton_method(:subscribe) { |_| raise kind, "broken" }
      setup = run_setup(config)

      assert_match "Packrat: Rails.error failed (#{kind.name}: broken)", log
      assert_equal :configured, setup.outcome
    end

    define_method(:"test_append_#{kind.name.downcase}") do
      provider = sdk_provider
      provider.define_singleton_method(:add_span_processor) { |_| raise kind, "broken #{CANARY}" }
      setup = run_setup(config)

      assert_match "Packrat: traces processor failed (#{kind.name}: broken [redacted])", log
      assert_equal "Packrat: the app's OpenTelemetry was left alone, and nothing is sent", setup.line
    end
  end

  def test_a_failed_sdk_configures_nothing_further
    setup = run_setup(config) { |subject| fail_in(subject, :configure_sdk, StandardError) }

    assert_equal "Packrat: OpenTelemetry was not configured, so nothing is sent", setup.line
    assert_empty setup.installed
    assert_empty @errors.subscribers
  end

  def test_a_failed_logs_sdk_still_sends_traces
    setup = run_setup(config) { |subject| fail_in(subject, :load_logs, LoadError) }

    assert_equal :configured, setup.outcome
    assert_match "Packrat: sending traces for shop/production", setup.line
  end

  def test_an_instrumentation_that_must_load_during_boot_is_a_warning
    run_setup(config({ "PACKRAT_OTEL_INSTRUMENTATIONS" => "action_mailer" }))

    assert_match "Packrat: instrumentation action_mailer failed (ArgumentError: the action_mailer instrumentation must load before boot ends", log
  end

  def test_an_unknown_instrumentation_is_a_warning
    setup = run_setup(config({ "PACKRAT_OTEL_INSTRUMENTATIONS" => "no_such_library" }))

    assert_match "Packrat: instrumentation no_such_library failed (LoadError", log
    assert_equal :configured, setup.outcome
  end

  private

  # Every call of the step raises, with the key in the message to prove the warning redacts it.
  def fail_in(subject, method, kind)
    subject.define_singleton_method(method) { |*| raise kind, "broken #{CANARY}" }
  end
end
