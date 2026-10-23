require "test_helper"

class ConfigTest < PackratTest
  def test_defaults
    config = Packrat::Config.new(env: { "PACKRAT_INGEST_KEY" => CANARY }, rails_env: "production", app_name: "shop")

    assert_equal "https://ingest.packrat.sh", config.url
    assert_equal "https://ingest.packrat.sh/v1/traces", config.traces_endpoint
    assert_equal "https://ingest.packrat.sh/v1/logs", config.logs_endpoint
    assert_equal({ "Authorization" => CANARY }, config.headers)
    assert_equal %w[rack action_pack action_view active_job active_record net_http pg mysql2 sidekiq redis aws_sdk concurrent_ruby rake logger], config.instrumentations
    assert config.enabled?
  end

  def test_names_come_from_rails_when_the_standard_variables_are_unset
    config = config({ "HEROKU_SLUG_COMMIT" => "abc123", "DYNO" => "web.1" })

    assert_equal "shop", config.service_name
    assert_equal "production", config.environment
    assert_equal({ "service.name" => "shop", "deployment.environment.name" => "production", "service.version" => "abc123",
                   "service.instance.id" => "web.1" }, config.resource_attributes)
    assert_equal Socket.gethostname, config({}).resource_attributes["service.instance.id"]
  end

  def test_standard_variables_win
    config = config({ "OTEL_SERVICE_NAME" => "storefront", "BUILD_COMMIT" => "abc123",
                      "OTEL_RESOURCE_ATTRIBUTES" => "deployment.environment=staging,service.version=v9,service.instance.id=a" })

    assert_equal "storefront", config.service_name
    assert_equal "staging", config.environment
    assert_equal "v9", config.service_version
    assert_empty config.resource_attributes
  end

  def test_service_name_from_resource_attributes
    config = config({ "OTEL_RESOURCE_ATTRIBUTES" => "service.name=api" })

    assert_equal "api", config.service_name
    refute config.resource_attributes.key?("service.name")
  end

  def test_off_reasons
    assert_equal "no ingest key is set (PACKRAT_INGEST_KEY or config.ingest_key), so nothing is sent", config({ "PACKRAT_INGEST_KEY" => "" }).off_reason
    assert_equal "PACKRAT_DISABLED is set, so nothing is sent", config({ "PACKRAT_DISABLED" => "1" }).off_reason
    assert_equal "OTEL_SDK_DISABLED is true, so nothing is sent", config({ "OTEL_SDK_DISABLED" => "true" }).off_reason
    assert_nil config({ "PACKRAT_DISABLED" => "1" }, rails_env: "test").off_reason
    refute config(rails_env: "test").enabled?
    refute config({ "PACKRAT_DISABLED" => "1" }).enabled?
    assert config({ "PACKRAT_DISABLED" => "0" }).enabled?
  end

  def test_the_key_from_the_initializer
    config = config({ "PACKRAT_INGEST_KEY" => "" })
    refute config.enabled?
    assert config.allowed?

    config.ingest_key = CANARY
    assert_equal CANARY, config.key
    assert config.enabled?
  end

  def test_the_url_from_the_initializer
    configured = config({ "PACKRAT_INGEST_URL" => "" })
    configured.ingest_url = "http://localhost:3100/"
    assert_equal "http://localhost:3100", configured.url

    configured = config
    configured.ingest_url = "http://localhost:3100"
    assert_equal URL, configured.url
  end

  def test_the_variable_wins_over_the_initializer
    configured = config
    configured.ingest_key = "packrat_ingest_from_initializer"

    assert_equal CANARY, configured.key
  end

  def test_instrumentations_add_and_remove
    config = config({ "PACKRAT_OTEL_INSTRUMENTATIONS" => "faraday, -pg,rack,sidekiq" })

    assert_equal %w[rack action_pack action_view active_job active_record net_http mysql2 sidekiq redis aws_sdk concurrent_ruby rake logger faraday],
                 config.instrumentations
  end

  def test_app_exports_to_packrat
    assert config({ "PACKRAT_INGEST_URL" => "", "OTEL_EXPORTER_OTLP_ENDPOINT" => "https://ingest.packrat.sh" }).app_exports_to_packrat?
    assert config({ "PACKRAT_INGEST_URL" => "", "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT" => "https://ingest.packrat.sh/v1/traces" }).app_exports_to_packrat?
    refute config({ "OTEL_EXPORTER_OTLP_ENDPOINT" => "https://api.honeycomb.io" }).app_exports_to_packrat?
    refute config({ "OTEL_EXPORTER_OTLP_ENDPOINT" => "not a url ::" }).app_exports_to_packrat?
    refute config({ "OTEL_EXPORTER_OTLP_ENDPOINT" => "http://127.0.0.1:4318" }).app_exports_to_packrat?
  end

  def test_inspect_redacts_the_key
    config = self.config

    refute_includes config.inspect, CANARY
    refute_includes config.to_s, CANARY
    assert_includes config.inspect, "[redacted]"
  end
end
