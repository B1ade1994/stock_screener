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
  before_create :append_to_list
  scope :in_display_order, -> { order(:position, :id) }
  scope :watched, -> { where(enabled: true).where('expiration_date IS NULL OR expiration_date >= ?', Date.current) }
  def move_in_list!(target_id:, placement:)
    raise ArgumentError, "Invalid placement" unless %w[before after].include?(placement)

    self.class.with_order_lock do
      instruments = self.class.in_display_order.lock.to_a
      current = instruments.find { |instrument| instrument.id == id }
      target = instruments.find { |instrument| instrument.id.to_s == target_id.to_s }
      raise ActiveRecord::RecordNotFound unless current && target
      next if current == target

      instruments.delete(current)
      index = instruments.index(target) + (placement == "after" ? 1 : 0)
      instruments.insert(index, current)
      instruments.each_with_index do |instrument, position|
        instrument.update_columns(position: position) unless instrument.position == position
      end
    end
    reload
  end

  def self.with_order_lock
    transaction do
      # Shared by creation and reordering; scoped to this PostgreSQL database.
      connection.execute("SELECT pg_advisory_xact_lock(1397965650)")
      yield
    end
  end

  def future? = kind == "futures"
  def expired? = expiration_date.present? && expiration_date < Date.current
  def volume_unit = "лот."

  private

  def append_to_list
    self.class.with_order_lock do
      self.position = (self.class.maximum(:position) || -1) + 1
    end
  end
end
