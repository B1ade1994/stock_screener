# Stock Screener
Rails 8.1, PostgreSQL 16, Hotwire, Solid Queue. Read-only market data only.
Never place orders. Never print tokens or commit .env. Keep TLS verification enabled.
Volume detection uses minute data; support/resistance uses daily and weekly candles.
Use RSpec for Rails tests in `spec/`; do not add Minitest tests.
Run the full suite with `make test`, Rails specs with `make rspec spec=<path or RSpec arguments>`, and JavaScript collector tests with `make collector-test`.
