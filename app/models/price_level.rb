class PriceLevel < ApplicationRecord
  belongs_to :instrument
  validates :timeframe, inclusion: { in: %w[day week] }
  validates :side, inclusion: { in: %w[support resistance] }
  validates :source, inclusion: { in: %w[manual automatic] }
  validates :status, inclusion: { in: %w[candidate confirmed broken archived] }
  validates :price, numericality: { greater_than: 0 }
  validates :lower_price, :upper_price, :atr, numericality: { greater_than: 0 }, allow_nil: true
  validate :ordered_bounds
  scope :active, -> { where(active: true) }
  scope :alertable, -> { active.where(status: "confirmed") }

  def lower_bound = lower_price || price
  def upper_bound = upper_price || price
  def breakout_buffer = atr&.positive? ? [atr * BigDecimal("0.1"), BigDecimal("0.000000001")].max : price * BigDecimal("0.001")

  def crossed?(previous, current)
    Detectors::Levels.crossed?(side: side, price: price, previous: previous, current: current,
      lower: lower_bound, upper: upper_bound, buffer: breakout_buffer)
  end

  def distance_percent(current_price)
    return unless current_price&.positive?
    ((price - current_price) / current_price * 100).to_f
  end

  private
  def ordered_bounds
    errors.add(:lower_price, "должна быть не больше верхней границы") if lower_bound > upper_bound
  end
end
