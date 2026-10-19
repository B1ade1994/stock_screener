class RefreshDirectionalHintsJob < ApplicationJob
  limits_concurrency to: 1, key: 'directional-hints', duration: 2.minutes

  def perform
    # Include disabled instruments with pending research so they still expire.
    active_ids = MarketSignal.where(kind: DirectionalHints::KIND).where("details ->> 'monitoring' = 'true'").select(:instrument_id)
    lifecycle_ids = MarketSignal.where(kind: DirectionalHints::KIND).where("details -> 'lifecycle' ->> 'status' = 'pending'").pluck(:instrument_id)
    ids = [] # No new minute candidates; preserve pending outcome accounting.
    (ids + active_ids.pluck(:instrument_id) + lifecycle_ids).uniq.each do |id|
      instrument = Instrument.find_by(id: id)
      DirectionalHints.call(instrument) if instrument
    rescue ActiveRecord::RecordNotFound
      next
    end
  end
end
