.PHONY: up down logs test rspec collector-test console

spec ?= spec

up:
	docker compose up --build -d
down:
	docker compose down
logs:
	docker compose logs -f web worker collector
console:
	docker compose exec web bin/rails console
test: rspec collector-test
rspec:
	docker compose exec -e RAILS_ENV=test web bin/rails db:test:prepare
	docker compose exec -e RAILS_ENV=test web bundle exec rspec $(spec)
collector-test:
	docker compose run --rm --no-deps collector node --test collector/aggregator.test.mjs
