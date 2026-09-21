class SignalReaction < ApplicationRecord
  HORIZONS = [5, 15, 30, 60].freeze
  SETTLE_DELAY = 30.seconds
  MISSING_GRACE = 10.minutes
  MAX_RETRY_AGE = 24.hours

  belongs_to :signal, class_name: "MarketSignal"
  scope :due, ->(now) { where("next_check_at <= ?", now) }

  def pending_horizons = HORIZONS.reject { |minutes| results.key?(minutes.to_s) }

  def unavailable!(reason)
    remaining = pending_horizons.to_h { |h| [h.to_s, { "status" => "unavailable", "reason" => reason }] }
    update!(results: results.merge(remaining), next_check_at: nil, last_error: nil)
  end
end
