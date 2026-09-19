class Instrument < ApplicationRecord
  has_many :candles, dependent: :delete_all
  has_many :price_levels, dependent: :destroy
  has_many :market_minutes, dependent: :delete_all
  has_many :signals, class_name: "MarketSignal", dependent: :delete_all
  validates :uid, :ticker, :name, :class_code, :currency, presence: true
  validates :uid, uniqueness: true
  validates :kind, inclusion: { in: %w[share futures] }
  validates :volume_multiplier, numericality: { greater_than_or_equal_to: 1.5, less_than_or_equal_to: 100 }
  validates :minimum_volume, numericality: { only_integer: true, greater_than: 0 }
  scope :watched, -> { where(enabled: true).where('expiration_date IS NULL OR expiration_date >= ?', Date.current) }
  def future? = kind == "futures"
  def expired? = expiration_date.present? && expiration_date < Date.current
  def volume_unit = "лот."
end
