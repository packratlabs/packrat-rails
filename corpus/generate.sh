#!/bin/bash
# Makes a `rails new` app for each Rails version under corpus/generated/, with nothing that needs a
# service to boot. Usage: corpus/generate.sh [8.1 8.0 7.2 7.1]
set -euo pipefail

cd "$(dirname "$0")"
mkdir -p generated

for version in ${@:-8.1 8.0 7.2 7.1}; do
  # Each version knows only the --skip flags of the generators it ships.
  flags="--database=sqlite3 --skip-javascript --skip-hotwire --skip-git --skip-docker --skip-test --skip-system-test --quiet"
  case $version in
    8.1) full=8.1.3.1; flags="$flags --skip-kamal --skip-thruster --skip-solid --skip-ci --skip-brakeman --skip-rubocop --skip-bundler-audit" ;;
    8.0) full=8.0.2.1; flags="$flags --skip-kamal --skip-thruster --skip-solid --skip-ci --skip-brakeman --skip-rubocop" ;;
    7.2) full=7.2.2.2; flags="$flags --skip-ci --skip-brakeman --skip-rubocop" ;;
    7.1) full=7.1.5.2 ;;
    *) echo "unknown Rails version $version" >&2; exit 1 ;;
  esac
  app=generated/rails-$version
  if [ -d "$app" ]; then echo "$app exists"; continue; fi
  gem list -i rails -v "$full" >/dev/null || gem install rails -v "$full" --no-document
  rails "_${full}_" new "$app" $flags
  # A route to a controller, so the boot proof's request has an action to name its span.
  sed -i '' 's|^Rails.application.routes.draw do$|&\
  get "hello" => "rails/welcome#index"|' "$app/config/routes.rb"
done
