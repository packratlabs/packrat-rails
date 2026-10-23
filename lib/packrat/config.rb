require "socket"
require "uri"

module Packrat
  # Everything the gem reads, all of it from the environment. An OTEL_* variable that is set always
  # wins: the gem fills in only what the standard variables leave empty.
  class Config
    DEFAULT_URL = "https://ingest.packrat.sh".freeze
    INSTRUMENTATIONS = %w[rack action_pack action_view active_job active_record net_http pg mysql2 sidekiq redis aws_sdk concurrent_ruby rake logger].freeze
    COMMIT_VARIABLES = %w[BUILD_COMMIT HEROKU_SLUG_COMMIT SOURCE_VERSION].freeze
    REDACTED = "[redacted]".freeze

    attr_reader :rails_env, :app_name
    attr_writer :ingest_key

    def initialize(env: ENV, rails_env: nil, app_name: nil)
      @env = env
      @rails_env = rails_env.to_s
      @app_name = app_name
    end

    # The variable wins over the initializer, so a deploy can change the key without a commit.
    def key
      present(@env["PACKRAT_INGEST_KEY"]) || present(@ingest_key)
    end

    def url
      (present(@env["PACKRAT_INGEST_URL"]) || DEFAULT_URL).chomp("/")
    end

    def traces_endpoint
      "#{url}/v1/traces"
    end

    def logs_endpoint
      "#{url}/v1/logs"
    end

    def headers
      { "Authorization" => key }
    end

    # Why the gem does nothing, or nil when it runs. Test is silent: a line per test process is noise.
    def off_reason
      if rails_env == "test" then nil
      elsif flag?("PACKRAT_DISABLED") then "PACKRAT_DISABLED is set, so nothing is sent"
      elsif sdk_disabled? then "OTEL_SDK_DISABLED is true, so nothing is sent"
      elsif key.nil? then "no ingest key is set (PACKRAT_INGEST_KEY or config.ingest_key), so nothing is sent"
      end
    end

    def enabled?
      allowed? && !key.nil?
    end

    # Everything but the key. The middleware is placed before config/initializers set the key.
    def allowed?
      rails_env != "test" && !flag?("PACKRAT_DISABLED") && !sdk_disabled?
    end

    # PACKRAT_OTEL_INSTRUMENTATIONS=sidekiq,-pg adds sidekiq to the allowlist and takes pg out.
    def instrumentations
      @env["PACKRAT_OTEL_INSTRUMENTATIONS"].to_s.split(",").map(&:strip).reject(&:empty?)
        .reduce(INSTRUMENTATIONS.dup) do |names, entry|
          entry.start_with?("-") ? names - [ entry.delete_prefix("-") ] : names | [ entry ]
        end
    end

    def service_name
      present(@env["OTEL_SERVICE_NAME"]) || env_attributes["service.name"] || app_name
    end

    def environment
      env_attributes["deployment.environment.name"] || env_attributes["deployment.environment"] || rails_env
    end

    def service_version
      env_attributes["service.version"] || COMMIT_VARIABLES.lazy.map { |name| present(@env[name]) }.find(&:itself)
    end

    # Only what the standard variables leave unset; the SDK's default resource already holds theirs.
    def resource_attributes
      {}.tap do |attributes|
        attributes["service.name"] = app_name if app_name && service_name == app_name
        unless env_attributes.key?("deployment.environment.name") || env_attributes.key?("deployment.environment")
          attributes["deployment.environment.name"] = rails_env
        end
        version = service_version
        attributes["service.version"] = version if version && !env_attributes.key?("service.version")
        # DYNO names the process on Heroku and build.io: web.1, worker.2.
        attributes["service.instance.id"] = present(@env["DYNO"]) || Socket.gethostname unless env_attributes.key?("service.instance.id")
      end
    end

    def set?(name)
      !present(@env[name]).nil?
    end

    # The app's own exporter names the ingest host, so a second exporter would send every span twice.
    def app_exports_to_packrat?
      ours = URI(url).then { |uri| [ uri.host, uri.port ] }
      %w[OTEL_EXPORTER_OTLP_ENDPOINT OTEL_EXPORTER_OTLP_TRACES_ENDPOINT].any? do |name|
        (URI(present(@env[name]).to_s).then { |uri| [ uri.host, uri.port ] } rescue nil) == ours
      end
    end

    def inspect
      "#<#{self.class.name} url=#{url} key=#{key ? REDACTED : 'unset'} service=#{service_name} environment=#{environment}>"
    end
    alias to_s inspect

    private

    # The SDK reads OTEL_RESOURCE_ATTRIBUTES the same way: split on commas, then on "=".
    def env_attributes
      @env_attributes ||= @env["OTEL_RESOURCE_ATTRIBUTES"].to_s.split(",").filter_map do |pair|
        name, value = pair.split("=", 2).map { |part| part.to_s.strip }
        [ name, value ] unless name.empty? || value.empty?
      end.to_h
    end

    def sdk_disabled?
      @env["OTEL_SDK_DISABLED"].to_s.strip.casecmp?("true")
    end

    def flag?(name)
      value = present(@env[name])
      !value.nil? && !%w[0 false no].include?(value.downcase)
    end

    def present(value)
      value = value.to_s.strip
      value.empty? ? nil : value
    end
  end
end
