class RefreshTechnicalStudiesJob < ApplicationJob
  queue_as :default
  limits_concurrency to: 1, key: 'technical-studies', duration: 2.minutes

  def perform
    now = Time.current
    MarketSignal.where("details -> 'technical_study' ->> 'status' = 'pending'").find_each do |signal|
      signal.instrument.with_lock do
        signal.reload
        TechnicalStudies.process(signal, now: now)
      end
    rescue ActiveRecord::RecordNotFound
      next
    end
  end
end
