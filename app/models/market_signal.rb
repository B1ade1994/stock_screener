class MarketSignal < ApplicationRecord
  self.table_name = "signals"
  belongs_to :instrument
end
