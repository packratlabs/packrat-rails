# Boots a Rails app with Packrat and prints the pages the browser boot test asserts on.
require "tmpdir"
require "json"
require "action_controller/railtie"
require "action_view/railtie"
require "packrat-rails"

ENV["PACKRAT_INGEST_KEY"] = "packrat_ingest_boot"
ENV["PACKRAT_INGEST_URL"] = "http://127.0.0.1:9"

root = Dir.mktmpdir
FileUtils.mkdir_p("#{root}/app/views/pages")
File.write("#{root}/app/views/pages/show.html.erb", "<html><head><title>Shop</title></head><body>show</body></html>")

module Shop
  class App < Rails::Application
    config.eager_load = false
    config.logger = Logger.new(nil)
    config.secret_key_base = "x" * 64
    config.hosts.clear
    config.content_security_policy { |policy| policy.script_src :self }
    config.content_security_policy_nonce_generator = ->(_request) { "n0nce" }
    config.content_security_policy_nonce_directives = %w[script-src]
    routes.append do
      get "/" => "pages#show"
      get "/plain" => "pages#plain"
    end
  end
end
Shop::App.config.root = root

class Current < ActiveSupport::CurrentAttributes
  attribute :user
end

class PagesController < ActionController::Base
  skip_packrat_browser only: :plain
  before_action { Current.user = Struct.new(:id).new(7) }

  def show = render(:show)
  def plain = render(:show)
end

Shop::App.initialize!

get = ->(path) { Rack::MockRequest.new(Shop::App).get(path) }
page, plain, script = get.("/"), get.("/plain"), get.("/packrat/browser-#{Packrat::VERSION}.js")
puts JSON.generate(
  outcome: Packrat.setup.outcome,
  page: page.body,
  csp: page.headers["content-security-policy"],
  plain: plain.body,
  script_status: script.status,
  script_type: script.headers["content-type"]
)
# The exporters' shutdown at exit retries a listener that is not there.
$stdout.flush
exit!(0)
