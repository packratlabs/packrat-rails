require "json"
require "rails/generators"

module Packrat
  module Generators
    # bin/rails generate packrat --ingest-key=packrat_ingest_...
    class PackratGenerator < Rails::Generators::Base
      namespace "packrat"
      source_root File.expand_path("templates", __dir__)

      desc "Creates config/initializers/packrat.rb, which gives the packrat-rails gem your ingest key, " \
           "and turns on the Packrat plugin for Claude Code in .claude/settings.json."
      class_option :ingest_key, type: :string, desc: "The ingest key from your Packrat setup page"
      class_option :ingest_url, type: :string, desc: "Where to send, when it isn't https://ingest.packrat.sh"
      class_option :claude_code, type: :boolean, default: true,
                                 desc: "Turn on the Packrat plugin for Claude Code in .claude/settings.json"

      CLAUDE_SETTINGS = ".claude/settings.json"
      MARKETPLACE = { "source" => { "source" => "github", "repo" => "packratlabs/claude-plugin" } }.freeze
      PLUGIN = "packrat@packrat"

      def create_initializer
        template "initializer.rb.tt", "config/initializers/packrat.rb"
      end

      # Everyone who opens Claude Code in the repository and trusts the folder gets the plugin. Other
      # settings in the file are kept, and so is a plugin someone turned off on purpose.
      def enable_claude_code_plugin
        return unless options[:claude_code]

        path = File.join(destination_root, CLAUDE_SETTINGS)
        return create_file(CLAUDE_SETTINGS, settings_json({})) unless File.exist?(path)

        current = JSON.parse(File.read(path))
        merged = settings_json(current)
        return say_status(:identical, CLAUDE_SETTINGS, :blue) if merged == File.read(path)

        File.write(path, merged)
        say_status :update, CLAUDE_SETTINGS
      rescue JSON::ParserError
        say_status :skip, "#{CLAUDE_SETTINGS} isn't valid JSON; add the Packrat plugin to it yourself", :yellow
      end

      private

      def ingest_key
        options[:ingest_key].to_s.strip
      end

      def ingest_url
        options[:ingest_url].to_s.strip
      end

      def settings_json(settings)
        settings = settings.dup
        settings["extraKnownMarketplaces"] = { "packrat" => MARKETPLACE }.merge(settings["extraKnownMarketplaces"] || {})
        settings["enabledPlugins"] = { PLUGIN => true }.merge(settings["enabledPlugins"] || {})
        "#{JSON.pretty_generate(settings)}\n"
      end
    end
  end
end
