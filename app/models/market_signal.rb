class MarketSignal < ApplicationRecord
  self.table_name = "signals"
  belongs_to :instrument
  has_one :reaction, class_name: "SignalReaction", foreign_key: :signal_id, dependent: :delete
  after_create :start_price_tracking

  scope :recent_activity, -> { order(Arel.sql("COALESCE(last_occurred_at, occurred_at) DESC, signals.id DESC")) }

  def episode? = kind == "volume" && episode_direction.present?
  def price_direction
    details["price_direction"] if kind == "volume"
  end

  private

  def start_price_tracking
    reference = Time.at((created_at.to_i / 60 + 1) * 60).utc
    create_reaction!(reference_at: reference, next_check_at: reference + 5.minutes + SignalReaction::SETTLE_DELAY)
  end
end
