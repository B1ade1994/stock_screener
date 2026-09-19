require_relative "boot"
require "rails/all"
Bundler.require(*Rails.groups)
module StockScreener
  class Application < Rails::Application
    config.load_defaults 8.1
    config.generators.test_framework :rspec
    config.autoload_lib(ignore: %w[assets tasks])
    config.time_zone = "Europe/Moscow"
    config.active_job.queue_adapter = :solid_queue
    config.solid_queue.connects_to = { database: { writing: :queue } }
  end
end
