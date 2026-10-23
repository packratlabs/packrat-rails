require "rails/generators"

module Packrat
  module Generators
    # bin/rails generate packrat --ingest-key=packrat_ingest_...
    class PackratGenerator < Rails::Generators::Base
      namespace "packrat"
      source_root File.expand_path("templates", __dir__)

      desc "Creates config/initializers/packrat.rb, which gives the packrat-rails gem your ingest key."
      class_option :ingest_key, type: :string, desc: "The ingest key from your Packrat setup page"

      def create_initializer
        template "initializer.rb.tt", "config/initializers/packrat.rb"
      end

      private

      def ingest_key
        options[:ingest_key].to_s.strip
      end
    end
  end
end
