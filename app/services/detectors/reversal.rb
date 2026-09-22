module Detectors
  # Versioned starting rules, not calibrated trading recommendations. Uses only
  # validated completed OHLCV minutes before or at the time of detection.
  class Reversal
    VERSION = 2
    BASELINE = 20
    REBOUND = 3
    WINDOWS = [5, 60, 120, 240, 480].freeze

    def self.valid_bar?(bar)
      prices = [bar.open_price, bar.high_price, bar.low_price, bar.close_price]
      bar.complete && prices.all? { |p| p && p.finite? && p.positive? } &&
        bar.high_price >= [bar.open_price, bar.close_price].max &&
        bar.low_price <= [bar.open_price, bar.close_price].min
    end

    def self.evaluate(bars:)
      # Prefer the longer context if the same rebound meets several scenarios.
      WINDOWS.reverse_each do |minutes|
        window = bars.last(BASELINE + minutes + REBOUND)
        next unless window.size == BASELINE + minutes + REBOUND
        next unless window.all? { |b| valid_bar?(b) && b.time.in_time_zone.to_date == window.last.time.in_time_zone.to_date }
        next unless window.each_cons(2).all? { |a, b| b.time - a.time == 60 }
        baseline = window.first(BASELINE)
        impulse = window.slice(BASELINE, minutes)
        rebound = window.last(REBOUND)
        ranges = baseline.each_with_index.map do |b, index|
          previous = index.zero? ? b.open_price : baseline[index - 1].close_price
          [b.high_price - b.low_price, (b.high_price - previous).abs, (b.low_price - previous).abs].max.to_f
        end
        volatility = ranges.sum / BASELINE
        next unless volatility.positive?
        volumes = baseline.map(&:volume).sort
        median_volume = (volumes[9] + volumes[10]) / 2.0
        next unless median_volume.positive?
        rebound_volume = rebound.sum(&:volume)
        relative_volume = rebound_volume / (median_volume * REBOUND)
        next unless rebound_volume >= 10 && relative_volume >= 1.5

        start = impulse.first.open_price.to_f
        finish = impulse.last.close_price.to_f
        move = finish - start
        next if move.zero?
        direction = move.negative? ? 1 : -1
        path = [start] + impulse.map { |b| b.close_price.to_f }
        distance = path.each_cons(2).sum { |a, b| (b - a).abs }
        next unless distance.positive? && move.abs / distance >= 0.55
        next unless move.abs >= volatility * (minutes == 5 ? 4 : 6)
        next unless move.abs / start >= (minutes == 5 ? 0.0015 : 0.004)

        extreme = direction == 1 ? impulse.map(&:low_price).min.to_f : impulse.map(&:high_price).max.to_f
        # No fresh extreme during the rebound; require higher/lower closes.
        next unless rebound.all? { |b| direction == 1 ? b.low_price.to_f >= extreme : b.high_price.to_f <= extreme }
        next unless rebound.each_cons(2).all? { |a, b| direction * (b.close_price - a.close_price) > 0 }
        recovery = direction * (rebound.last.close_price.to_f - finish)
        retracement = recovery / move.abs
        next unless recovery >= volatility * 1.5 && retracement.between?(0.2, 0.85)

        return {
          version: VERSION, direction: direction == 1 ? 'up' : 'down',
          scenario: minutes == 5 ? 'sharp' : 'sustained', impulse_minutes: minutes,
          impulse_percent: (move / start * 100).round(2),
          rebound_percent: ((rebound.last.close_price.to_f - finish) / finish * 100).round(2),
          retracement_percent: (retracement * 100).round(1), relative_volume: relative_volume.round(2),
          volatility: volatility, extreme: extreme, entry_price: rebound.last.close_price.to_s,
          history_source: "completed_ohlcv", last_checked_at: window.last.time.iso8601, confirmation_closes: 0
        }
      end
      nil
    end
  end
end
