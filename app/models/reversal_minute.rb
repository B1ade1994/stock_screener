# Canonical completed OHLCV, separate from directional trade volumes.
class ReversalMinute < ApplicationRecord
  belongs_to :instrument
  validates :volume, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :data_source, inclusion: { in: %w[stream t_invest] }
  validate :valid_ohlc

  def complete = true

  def self.record_stream(instrument, bar)
    return unless Detectors::Reversal.valid_bar?(bar) && bar.time + 95.seconds <= Time.current
    attributes = bar.attributes.slice('time', 'open_price', 'high_price', 'low_price', 'close_price')
      .merge('instrument_id' => instrument.id, 'volume' => bar.volume, 'data_source' => 'stream', 'source_session' => bar.session)
    candidate = new(attributes)
    return unless candidate.valid?
    # Replayed snapshots must never replace an authoritative exchange candle.
    insert_all([attributes], unique_by: [:instrument_id, :time])
  end

  private

  def valid_ohlc
    errors.add(:base, 'Invalid completed minute') unless time && time.sec.zero? && time.subsec.zero? && Detectors::Reversal.valid_bar?(self)
  end
end
