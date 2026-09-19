class Candle < ApplicationRecord
  belongs_to :instrument

  def reference? = data_source == "yahoo_spy"
  def source_label = reference? ? "SPY · Yahoo Finance" : "Т-Инвестиции"
end
