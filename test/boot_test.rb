require "test_helper"
require "json"
require "open3"
require "rbconfig"

# Packrat decides at the end of a real boot, which the other tests stand in for. This one boots.
class BootTest < Minitest::Test
  def test_action_view_subscribes_once_and_leaves_no_context_attached
    output, status = Open3.capture2e({ "RAILS_ENV" => "production" }, RbConfig.ruby, "-Ilib", File.expand_path("boot/action_view.rb", __dir__))
    assert status.success?, output
    result = JSON.parse(output.lines.last)

    assert_equal "configured", result["outcome"]
    assert_equal [ 1 ], result["subscribers"].values.uniq, result["subscribers"].inspect
    assert_equal 0, result["context_depth"]
    assert_empty result["errors"]
    assert_equal [ "GET /", "GET /" ], result["roots"].map { |name| name.sub("HTTP GET", "GET /") }
    assert_equal 6, result["render_spans"]
  end

  def test_pages_send_browser_events
    output, status = Open3.capture2e({ "RAILS_ENV" => "production" }, RbConfig.ruby, "-Ilib", File.expand_path("boot/browser.rb", __dir__))
    assert status.success?, output
    result = JSON.parse(output.lines.last)
    tag = result["page"][/<script defer [^>]*><\/script>/]

    assert_equal "configured", result["outcome"]
    assert_match %r{\A<script defer src="/packrat/browser-#{Packrat::VERSION}\.js" data-config="[^"]+" nonce="n0nce"></script>\z}, tag
    assert_includes result["page"], "#{tag}</head>"
    assert_includes tag, "&quot;user&quot;:&quot;7&quot;"
    assert_includes result["csp"], "'nonce-n0nce'"
    refute_includes result["plain"], "<script"
    assert_equal 200, result["script_status"]
    assert_equal "text/javascript", result["script_type"]
  end
end
