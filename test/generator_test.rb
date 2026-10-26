require "test_helper"
require "fileutils"
require "json"
require "tmpdir"
require "generators/packrat/packrat_generator"

class GeneratorTest < PackratTest
  def test_writes_the_key_into_the_initializer
    initializer = generate("--ingest-key=#{CANARY}")

    assert_includes initializer, %(config.ingest_key = ENV.fetch("PACKRAT_INGEST_KEY", "#{CANARY}"))
    assert_equal CANARY, evaluate(initializer, nil).key
    assert_equal "packrat_ingest_from_env", evaluate(initializer, "packrat_ingest_from_env").key
  end

  def test_an_ingest_url
    initializer = generate("--ingest-key=#{CANARY}", "--ingest-url=http://localhost:3100")

    assert_includes initializer, %(config.ingest_url = "http://localhost:3100")
    assert_equal "http://localhost:3100/v1/traces", evaluate(initializer, nil).traces_endpoint
    refute_includes generate("--ingest-key=#{CANARY}"), "ingest_url"
  end

  def test_without_a_key_reads_the_variable
    initializer = generate

    assert_includes initializer, %(config.ingest_key = ENV["PACKRAT_INGEST_KEY"])
    assert_nil evaluate(initializer, nil).key
  end

  def test_turns_on_the_claude_code_plugin
    settings = JSON.parse(claude_settings)

    assert_equal({ "source" => { "source" => "github", "repo" => "packratlabs/claude-plugin" } },
                 settings.dig("extraKnownMarketplaces", "packrat"))
    assert_equal true, settings.dig("enabledPlugins", "packrat@packrat")
  end

  def test_keeps_the_rest_of_the_claude_code_settings
    before = { "permissions" => { "allow" => [ "Bash(bin/rails test:*)" ] },
               "enabledPlugins" => { "ruby-lsp@claude-plugins-official" => true } }
    settings = JSON.parse(claude_settings(JSON.generate(before)))

    assert_equal [ "Bash(bin/rails test:*)" ], settings.dig("permissions", "allow")
    assert_equal true, settings.dig("enabledPlugins", "ruby-lsp@claude-plugins-official")
    assert_equal true, settings.dig("enabledPlugins", "packrat@packrat")
  end

  def test_leaves_a_plugin_turned_off_on_purpose
    settings = JSON.parse(claude_settings(JSON.generate("enabledPlugins" => { "packrat@packrat" => false })))

    assert_equal false, settings.dig("enabledPlugins", "packrat@packrat")
  end

  def test_running_twice_changes_nothing
    once = claude_settings
    assert_equal once, claude_settings(once)
  end

  def test_leaves_settings_it_cannot_read
    assert_equal "{ not json", claude_settings("{ not json")
  end

  def test_no_claude_code_writes_no_settings
    assert_nil claude_settings(nil, "--no-claude-code")
  end

  def test_rails_finds_it_as_packrat
    assert_equal Packrat::Generators::PackratGenerator, Rails::Generators.find_by_namespace("packrat")
  end

  private

  def generate(*args)
    Dir.mktmpdir do |root|
      Packrat::Generators::PackratGenerator.start([ *args, "--quiet" ], destination_root: root)
      File.read(File.join(root, "config/initializers/packrat.rb"))
    end
  end

  # The .claude/settings.json the generator leaves in a project that had existing (nil for none).
  def claude_settings(existing = nil, *args)
    Dir.mktmpdir do |root|
      path = File.join(root, ".claude/settings.json")
      if existing
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, existing)
      end
      Packrat::Generators::PackratGenerator.start([ *args, "--quiet" ], destination_root: root)
      File.exist?(path) ? File.read(path) : nil
    end
  end

  # Runs the initializer the way config/initializers would, with PACKRAT_INGEST_KEY set to variable.
  def evaluate(initializer, variable)
    saved = ENV.fetch("PACKRAT_INGEST_KEY", nil)
    variable ? ENV["PACKRAT_INGEST_KEY"] = variable : ENV.delete("PACKRAT_INGEST_KEY")
    Packrat.instance_variable_set(:@config, Packrat::Config.new(env: {}, rails_env: "production", app_name: "shop"))
    eval(initializer) # rubocop:disable Security/Eval
    Packrat.config
  ensure
    saved ? ENV["PACKRAT_INGEST_KEY"] = saved : ENV.delete("PACKRAT_INGEST_KEY")
    Packrat.instance_variable_set(:@config, nil)
  end
end
