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
end
