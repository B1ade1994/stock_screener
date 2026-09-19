class PriceLevel < ApplicationRecord
  belongs_to :instrument
  validates :timeframe, inclusion: { in: %w[day week] }
  validates :side, inclusion: { in: %w[support resistance] }
  validates :source, inclusion: { in: %w[manual automatic] }
  validates :price, numericality: { greater_than: 0 }
  scope :active, -> { where(active: true) }
end
