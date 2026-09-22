class MarketMinute < ApplicationRecord
  belongs_to :instrument
  def volume = buy + sell + unknown
end
