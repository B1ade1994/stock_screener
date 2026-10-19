# Compact volume history survives the seven-day OHLCV retention policy.
class MinuteVolumeSample < ApplicationRecord
  RETENTION_DAYS = 90
  belongs_to :instrument

  def self.day_type(date)
    date.saturday? ? 'saturday' : date.sunday? ? 'sunday' : 'weekday'
  end
end
