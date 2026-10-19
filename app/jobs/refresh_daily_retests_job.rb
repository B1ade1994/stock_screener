class RefreshDailyRetestsJob < ApplicationJob
  limits_concurrency to: 1, key: 'daily-retests', duration: 10.minutes

  def perform
    Instrument.where(kind: %w[futures currency]).find_each do |instrument|
      DailyRetestResearch.call(instrument)
      DailySupportBounceResearch.call(instrument)
    end
  end
end
