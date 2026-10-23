require "test_helper"
require "tmpdir"
require "generators/packrat/packrat_generator"

class GeneratorTest < PackratTest
  def test_writes_the_key_into_the_initializer
    initializer = generate("--ingest-key=#{CANARY}")

    assert_includes initializer, %(config.ingest_key = ENV.fetch("PACKRAT_INGEST_KEY", "#{CANARY}"))
    assert_equal CANARY, evaluate(initializer, nil).key
    assert_equal "packrat_ingest_from_env", evaluate(initializer, "packrat_ingest_from_env").key
  end

  def test_without_a_key_reads_the_variable
    initializer = generate

    assert_includes initializer, %(config.ingest_key = ENV["PACKRAT_INGEST_KEY"])
    assert_nil evaluate(initializer, nil).key
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
