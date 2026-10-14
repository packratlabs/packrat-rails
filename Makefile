.PHONY: check test lint

check: lint test

lint:
	bundle exec rubocop

test:
	bundle exec rake test
