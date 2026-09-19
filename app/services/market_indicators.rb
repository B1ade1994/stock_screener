# Calculations use completed bars in ascending order. Every output is prefix-safe.
class MarketIndicators
  def self.ema(candles, period)
    values = Array.new(candles.size)
    return values if candles.size < period
    value = candles.first(period).sum { |c| c.close.to_f } / period
    values[period - 1] = value
    (period...candles.size).each do |i|
      value += 2.0 / (period + 1) * (candles[i].close.to_f - value)
      values[i] = value
    end
    values
  end

  def self.atr(candles, period = 14)
    ranges = candles.each_with_index.map do |c, i|
      previous = i.positive? ? candles[i - 1].close.to_f : c.close.to_f
      [c.high.to_f - c.low.to_f, (c.high.to_f - previous).abs, (c.low.to_f - previous).abs].max
    end
    values = Array.new(candles.size)
    return values if candles.size < period
    value = ranges.first(period).sum / period
    values[period - 1] = value
    (period...candles.size).each { |i| values[i] = value = (value * (period - 1) + ranges[i]) / period }
    values
  end

  def self.context(candles, timeframe)
    periods = timeframe == "week" ? [20, 40] : [20, 50, 200]
    series = periods.to_h { |period| [period, ema(candles, period)] }
    { "as_of" => candles.last&.time&.iso8601, "close" => candles.last&.close&.to_f,
      "ema" => series.transform_values(&:last),
      "slope_5" => series.transform_values { |values| values.last && values[-6] ? values.last - values[-6] : nil } }
  end
end
