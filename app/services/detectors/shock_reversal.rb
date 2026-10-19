module Detectors
  # Research heuristic. Variable impulse length avoids making a five-minute
  # boundary the definition of a shock. No future bars or intraminute ordering.
  class ShockReversal
    BASELINE = 20
    MAX_IMPULSE = 15
    REBOUND = 2
    LOOKBACK = BASELINE + MAX_IMPULSE + REBOUND

    def self.evaluate(bars:)
      MAX_IMPULSE.downto(3) do |minutes|
        window = bars.last(BASELINE + minutes + REBOUND)
        next unless window.size == BASELINE + minutes + REBOUND
        next unless window.all? { |b| Reversal.valid_bar?(b) && b.time.in_time_zone.to_date == window.last.time.in_time_zone.to_date }
        next unless window.each_cons(2).all? { |a, b| b.time - a.time == 60 }
        baseline, impulse, rebound = window.first(BASELINE), window.slice(BASELINE, minutes), window.last(REBOUND)
        atr = baseline.each_with_index.sum do |b, i|
          previous = i.zero? ? b.open_price : baseline[i - 1].close_price
          [b.high_price - b.low_price, (b.high_price - previous).abs, (b.low_price - previous).abs].max
        end / BASELINE
        volumes = baseline.map(&:volume).sort
        median = (volumes[9] + volumes[10]) / 2.0
        next unless atr.positive? && median.positive?
        start, finish = impulse.first.open_price, impulse.last.close_price
        move = finish - start
        next unless move.abs >= atr * 6 && move.abs / start >= 0.015
        up = move.negative?
        sign = up ? 1 : -1
        extreme_bar = up ? impulse.min_by(&:low_price) : impulse.max_by(&:high_price)
        extreme = up ? extreme_bar.low_price : extreme_bar.high_price
        # Anchor to the actual fresh extreme, not an arbitrary old impulse end.
        next unless extreme_bar == impulse.last
        next unless rebound.all? { |b| up ? b.low_price >= extreme : b.high_price <= extreme }
        next unless sign * (rebound.last.close_price - rebound.first.close_price) > 0
        recovery = sign * (rebound.last.close_price - finish)
        next unless recovery >= atr && (recovery / move.abs).between?(0.15, 0.8)
        relative_volume = rebound.sum(&:volume) / (median * REBOUND)
        next unless rebound.sum(&:volume) >= 10 && relative_volume >= 1.5
        return { direction: up ? 'up' : 'down', scenario: 'shock', impulse_minutes: minutes,
          extreme: extreme.to_s, extreme_at: extreme_bar.time.iso8601, volatility: atr.to_s,
          entry_price: rebound.last.close_price.to_s,
          rebound_boundary: (up ? rebound.map(&:high_price).max : rebound.map(&:low_price).min).to_s,
          impulse_percent: (move / start * 100).round(3).to_f,
          relative_volume: relative_volume.round(2), history_source: 'completed_ohlcv', version: 1 }
      end
      nil
    end
  end
end
