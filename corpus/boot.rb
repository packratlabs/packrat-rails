# Boots a Rails app with the gem added by path, against a listener that records every request.
#
#   bundle exec ruby corpus/boot.rb corpus/generated/rails-8.1        a generated app, §8.3
#   bundle exec ruby corpus/boot.rb ../packrat-worktree --existing --expect=appended   a real app, §8.4
#
# --existing never writes the app's .env, which in a worktree is a link to the main checkout's.
# --ruby=3.1.6 runs the app under that rvm Ruby. Extra NAME=value arguments are passed to the app's process. Exits non-zero when a check fails.
require "bundler"
require "json"
require "open3"
require "socket"
require "zlib"
require "opentelemetry/exporter/otlp"
require "opentelemetry-exporter-otlp-logs"

CANARY = "packrat_ingest_CANARY_KEY_DO_NOT_PRINT_9c1e".freeze
GEM = File.expand_path("..", __dir__)
RUNNER = File.join(__dir__, "runner.rb")

# One HTTP/1.1 server thread per connection; the exporter keeps its connection open between batches.
class Listener
  Request = Struct.new(:path, :headers, :body, keyword_init: true)

  attr_reader :requests, :port

  def initialize
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @requests = Queue.new
    @thread = Thread.new { loop { serve(@server.accept) } }
  end

  def drain
    [].tap { |all| all << @requests.pop until @requests.empty? }
  end

  private

  def serve(socket)
    Thread.new do
      while (line = socket.gets)
        _, path = line.split
        headers = {}
        while (header = socket.gets) && header != "\r\n"
          name, value = header.split(":", 2)
          headers[name.downcase] = value.strip
        end
        body = socket.read(headers["content-length"].to_i)
        body = Zlib.gunzip(body) if headers["content-encoding"] == "gzip"
        @requests << Request.new(path:, headers:, body:)
        socket.write("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")
      end
    rescue IOError, SystemCallError
      nil
    ensure
      socket.close
    end
  end
end

class Boot
  def initialize(app, existing:, expect:, ruby:, env:)
    @app = File.expand_path(app)
    @ruby = ruby
    @existing = existing
    @expect = expect
    @env = env
    @failures = []
  end

  def call
    add_gem
    listener = Listener.new
    url = "http://127.0.0.1:#{listener.port}"
    dotenv = File.join(@app, ".env")
    File.write(dotenv, "PACKRAT_INGEST_KEY=#{CANARY}\nPACKRAT_INGEST_URL=#{url}\n") unless @existing || File.exist?(dotenv)

    off = run("PACKRAT_DISABLED" => "1", "PACKRAT_INGEST_URL" => url)
    listener.drain
    on = run("PACKRAT_INGEST_URL" => url)
    sleep 1
    requests = listener.drain

    puts "boot line: #{on['line']}"
    order = on["order"]
    puts "outcome: #{on['outcome']}; the gem's after_initialize block is #{on['after_initialize'].index { |hook| hook.include?('packrat/railtie.rb') }.to_i + 1} of #{on['after_initialize'].size}"
    check("config/initializers run before the middleware stack is built") { order.index("load_config_initializers") < order.index("build_middleware_stack") }
    # A block registered inside another after_initialize block runs at once, so it may follow the gem's.
    ours = on["after_initialize"].index { |hook| hook.include?("packrat/railtie.rb") }
    check("no after_initialize block of the app comes after the gem's") do
      ours && on["after_initialize"].drop(ours + 1).none? { |hook| File.realpath(hook.split(":").first).start_with?(File.realpath(@app)) }
    end
    check("no warnings #{on["warnings"]}") { on["warnings"].empty? }
    check("with PACKRAT_DISABLED=1 the gem is off") { off["outcome"] == "off" }
    check("outcome is #{@expect}") { on["outcome"] == @expect }
    check_append(off, on) if @expect == "appended"
    check_requests(requests, on)
    check_footprint(off, on)
    check_key_files
    puts @failures.empty? ? "PASS #{@app}" : "FAIL #{@app}: #{@failures.size} checks"
    @failures.empty?
  end

  private

  def add_gem
    gemfile = File.join(@app, "Gemfile")
    unless File.read(gemfile).include?("packrat-rails")
      File.write(gemfile, File.read(gemfile) + %(\ngem "packrat-rails", path: "#{GEM}"\n))
    end
    sh("bundle", "install", "--quiet")
  end

  def run(extra)
    env = { "PACKRAT_INGEST_KEY" => CANARY, "RAILS_ENV" => "development" }.merge(@env).merge(extra)
    output = sh(env, "bin/rails", "runner", RUNNER)
    line = output.lines.find { |found| found.start_with?("PACKRAT_BOOT ") } or abort("no report from the runner:\n#{output}")
    JSON.parse(line.delete_prefix("PACKRAT_BOOT "))
  end

  def sh(*command)
    env = command.first.is_a?(Hash) ? [ command.shift ] : []
    command = [ File.expand_path("~/.rvm/bin/rvm"), @ruby, "do", *command ] if @ruby
    Bundler.with_unbundled_env do
      output, status = Open3.capture2e(*env, *command, chdir: @app)
      abort("#{command.join(' ')} failed:\n#{output}") unless status.success?
      output
    end
  end

  # The app's own processors are still there, first and in order, and exactly one was added.
  def check_append(off, on)
    check("the app's own processors are untouched") { on["processors"].first(off["processors"].size) == off["processors"] }
    added = on["processors"].drop(off["processors"].size)
    check("one processor added, to the listener") { added.size == 1 && added[0]["uri"].end_with?("/v1/traces") }
    check("no instrumentation installed by the gem") { on["instrumentation"] == off["instrumentation"] }
  end

  def check_requests(requests, on)
    traces = requests.select { |request| request.path == "/v1/traces" }
    logs = requests.select { |request| request.path == "/v1/logs" }
    check("a POST to /v1/traces") { traces.any? }
    check("no request carries the logged credential") { requests.none? { |request| request.body.include?("boot-secret") } }
    check("Authorization is the key") { requests.any? && requests.all? { |request| request.headers["authorization"] == CANARY } }

    spans = traces.flat_map do |request|
      Opentelemetry::Proto::Collector::Trace::V1::ExportTraceServiceRequest.decode(request.body).resource_spans
    end
    error = spans.flat_map { |resource| resource.scope_spans.flat_map(&:spans).map { |span| [ resource, span ] } }
      .find { |_, span| span.name == "Rails.error" && span.events.any? { |event| event.name == "exception" } }
    check("a Rails.error span with an exception event") { error }
    server = spans.flat_map { |resource| resource.scope_spans.flat_map(&:spans) }
      .select { |span| span.kind == :SPAN_KIND_SERVER }
    puts "spans: #{spans.flat_map { |resource| resource.scope_spans.flat_map(&:spans) }.map { |span| [ span.name, span.kind ] }}"
    check("a server span named by its route, GET /hello") { server.any? { |span| span.name == "GET /hello" } } unless @existing
    check("no span for /up") { @expect == "appended" || server.none? { |span| span.attributes.any? { |attribute| attribute.value.string_value == "/up" } } }

    if logs.any? || on["line"].to_s.include?("logs")
      lines = logs.flat_map do |request|
        Opentelemetry::Proto::Collector::Logs::V1::ExportLogsServiceRequest.decode(request.body).resource_logs
          .flat_map { |resource| resource.scope_logs.flat_map(&:log_records) }
      end
      puts "log records: #{lines.size}, first: #{lines.first(3).map { |record| record.body.string_value[0, 60] }}"
      check("a POST to /v1/logs carrying hello") { lines.any? { |record| record.body.string_value.include?("hello") } }
    end

    return if @existing || error.nil?

    attributes = error[0].resource.attributes.to_h { |attribute| [ attribute.key, attribute.value.string_value ] }
    module_name = File.read(File.join(@app, "config/application.rb"))[/^module (\w+)/, 1]
    expected = module_name.gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase
    puts "resource: #{attributes.slice('service.name', 'deployment.environment.name', 'service.version')}"
    check("service.name is #{expected}") { attributes["service.name"] == expected }
    check("deployment.environment.name is development") { attributes["deployment.environment.name"] == "development" }
  end

  # Everything the gem adds to a process, against the same boot with PACKRAT_DISABLED=1.
  def check_footprint(off, on)
    middleware = on["middleware"] - off["middleware"]
    instrumentation = on["instrumentation"] - off["instrumentation"]
    subscribers = on["error_subscribers"] - off["error_subscribers"]
    puts "footprint: middleware #{middleware}, instrumentation #{instrumentation}, Rails.error #{subscribers}"
    check("footprint middleware is Packrat::RackSpan alone") { middleware == [ "Packrat::RackSpan" ] }
    check("off adds no middleware") { !off["middleware"].include?("Packrat::RackSpan") }
    named = on["line"].to_s[/\(([^)]*)\)(?:;|\z)/, 1].to_s.split(", ")
    check("every instrumentation installed is named in the boot line") do
      instrumentation.all? { |name| named.any? { |short| name.downcase.delete(":_").end_with?(short.delete("_")) } }
    end
  end

  def check_key_files
    files = Dir.glob("{log,tmp,storage}/**/*", base: @app).select { |path| File.file?(File.join(@app, path)) }
    leaks = files.select { |path| File.binread(File.join(@app, path)).include?(CANARY) }
    check("the key is in no log or tmp file (#{leaks.join(', ')})") { leaks.empty? }
  end

  def check(name)
    ok = yield
    puts "#{ok ? 'ok  ' : 'FAIL'} #{name}"
    @failures << name unless ok
  rescue StandardError => error
    puts "FAIL #{name}: #{error.class}: #{error.message}"
    @failures << name
  end
end

return unless $PROGRAM_NAME == __FILE__

app = ARGV.find { |arg| !arg.start_with?("--") && !arg.include?("=") } or abort("usage: boot.rb APP [--existing] [NAME=value]")
env = ARGV.grep(/\A[A-Z_]+=/).to_h { |pair| pair.split("=", 2) }
expect = ARGV.find { |arg| arg.start_with?("--expect=") }&.delete_prefix("--expect=") || "configured"
ruby = ARGV.find { |arg| arg.start_with?("--ruby=") }&.delete_prefix("--ruby=")
exit(Boot.new(app, existing: ARGV.include?("--existing"), expect:, ruby:, env:).call ? 0 : 1)
