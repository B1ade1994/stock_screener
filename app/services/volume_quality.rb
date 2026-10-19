# A visibility rule, not a claim that order flow predicts returns.
class VolumeQuality
  VERSION = 2
  def self.evaluate(instrument:, bar:, history:, time_baseline: nil)
    valid = ->(b) { [b.open_price, b.close_price, b.high_price, b.low_price].all? { |p| p && p.finite? && p.positive? } && b.high_price >= [b.open_price, b.close_price].max && b.low_price <= [b.open_price, b.close_price].min }
    change = if bar.open_price&.positive? && bar.close_price&.positive?
      ((bar.close_price / bar.open_price - 1) * 100).to_f
    end
    ranges = if history.size == 20 && history.all? { |b| valid.call(b) }
      history.each_with_index.map do |b, index|
        previous = index.zero? ? b.open_price : history[index - 1].close_price
        [b.high_price - b.low_price, (b.high_price - previous).abs, (b.low_price - previous).abs].max
      end
    end
    atr_percent = ranges && bar.open_price&.positive? ? (ranges.sum / ranges.size / bar.open_price * 100).to_f : nil
    threshold = [instrument.volume_min_change_percent.to_f, atr_percent.to_f * 0.5].max
    passed = valid.call(bar) && change && atr_percent && change.abs >= threshold
    price_passed = !!passed
    seasonal_rejection = time_baseline && time_baseline[:passed] == false
    reason = if !price_passed
      change && atr_percent ? 'small_move' : 'missing_prices'
    elsif seasonal_rejection
      'ordinary_for_time_of_day'
    else
      'meaningful_move'
    end
    { version: VERSION, enabled: instrument.volume_noise_filter?, passed: price_passed && !seasonal_rejection,
      price_passed: price_passed, time_baseline: time_baseline,
      change_percent: change&.round(6), atr_percent: atr_percent&.round(6), threshold_percent: threshold.round(6),
      reason: reason }
  end
end
