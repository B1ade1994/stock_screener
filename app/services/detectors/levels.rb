module Detectors
  class Levels
    VERSION = 2
    # Width / departure / reaction parameters are research heuristics, not fitted win rates.
    def self.candidates(candles, limit: 12, timeframe: "day")
      return [] if candles.size < 16
      atrs = MarketIndicators.atr(candles)
      result = %w[resistance support].flat_map do |side|
        pivots = (13...(candles.size - 2)).filter_map do |i|
          c = candles[i]
          atr = atrs[i]
          next unless atr&.positive?
          resistance = side == "resistance"
          value = resistance ? c.high.to_f : c.low.to_f
          next unless value.positive?
          body = resistance ? [c.open.to_f, c.close.to_f].max : [c.open.to_f, c.close.to_f].min
          neighbors = [i - 2, i - 1, i + 1, i + 2].map { |j| candles[j] }
          wick_extreme = neighbors.all? { |n| resistance ? value > n.high.to_f : value < n.low.to_f }
          body_extreme = neighbors.all? do |n|
            resistance ? body > [n.open.to_f, n.close.to_f].max : body < [n.open.to_f, n.close.to_f].min
          end
          next unless wick_extreme || body_extreme
          closes = candles[(i + 1)..(i + 2)].map { |n| n.close.to_f }
          reaction = [resistance ? value - closes.max : closes.min - value, 0].max
          next if reaction < 0.25 * atr
          # Include the relevant part of the body, but cap long wicks at 0.6 ATR.
          inner = resistance ? [body, value - 0.6 * atr].max : [body, value + 0.6 * atr].min
          lo, hi = [value, inner].minmax
          { price: value, lower: [lo - 0.15 * atr, 1e-9].max, upper: hi + 0.15 * atr,
            atr: atr, index: i, time: c.time, reference: c.reference?, reaction_atr: reaction / atr,
            reaction_percent: reaction / value * 100, relative_volume: relative_volume(candles, i, timeframe: timeframe) }
        end
        clusters = []
        pivots.each do |pivot|
          cluster = clusters.find do |items|
            lo = items.map { |p| p[:lower] }.min
            hi = items.map { |p| p[:upper] }.max
            width = [hi, pivot[:upper]].max - [lo, pivot[:lower]].min
            pivot[:lower] <= hi && pivot[:upper] >= lo && width <= 1.5 * median(items.map { |p| p[:atr] } + [pivot[:atr]])
          end
          if cluster
            previous = cluster.last
            next if pivot[:index] - previous[:index] < 3
            # The price must leave the previous reaction area before revisiting it.
            departed = candles[(previous[:index] + 1)...pivot[:index]].any? do |bar|
              side == "resistance" ? bar.close.to_f < previous[:lower] - 0.5 * previous[:atr] : bar.close.to_f > previous[:upper] + 0.5 * previous[:atr]
            end
            cluster << pivot if departed
          else
            clusters << [pivot]
          end
        end
        clusters.filter_map do |items|
          strong_single = items.first[:reaction_atr] >= 2 || (items.first[:reaction_atr] >= 1 && items.first[:relative_volume].to_f >= 1.5)
          next unless items.size >= 2 || strong_single
          ratios = items.filter_map { |p| p[:relative_volume] }
          score = items.sum do |p|
            age = candles.size - 1 - (p[:index] + 2)
            (1 + [[(p[:relative_volume] || 1) - 1, 0].max, 2].min + [p[:reaction_atr], 2].min) / (1 + age / 20.0)
          end
          lower = items.map { |p| p[:lower] }.min
          upper = items.map { |p| p[:upper] }.max
          { side: side, price: (lower + upper) / 2, lower_price: lower, upper_price: upper, atr: atrs.last,
            status: items.size >= 2 ? "confirmed" : "candidate", touches: items.size,
            assessment: { version: VERSION, reference_history: items.any? { |p| p[:reference] }, origin_side: side, score: score.round(2),
              relative_volume: ratios.any? ? (ratios.sum / ratios.size).round(2) : nil, volume_samples: ratios.size,
              volume_basis: timeframe == "week" ? "previous_20_weeks" : "previous_20_same_weekday_group",
              reaction_atr: (items.sum { |p| p[:reaction_atr] } / items.size).round(2),
              reaction_percent: (items.sum { |p| p[:reaction_percent] } / items.size).round(2),
              last_touch_at: items.last[:time]&.iso8601, as_of: candles.last.time&.iso8601 } }
        end
      end
      ranked = result.sort_by { |item| [-item[:assessment][:score], -item[:touches], item[:price]] }
      limit ? ranked.first(limit) : ranked
    end

    def self.relative_volume(candles, index, timeframe: "day")
      current = candles[index]
      return if current.volume.nil? || current.volume.negative?
      preceding = candles.first(index)
      if timeframe == "day"
        return unless current.time
        group = weekend?(current.time)
        preceding = preceding.select { |c| c.time && weekend?(c.time) == group }
      end
      volumes = preceding.last(20).map(&:volume)
      return unless volumes.size == 20 && volumes.none? { |v| v.nil? || v.negative? }
      baseline = median(volumes)
      current.volume / baseline if baseline.positive?
    end

    def self.weekend?(time)
      date = time.in_time_zone("Europe/Moscow")
      date.saturday? || date.sunday?
    end

    def self.median(values)
      sorted = values.sort
      (sorted[(sorted.size - 1) / 2] + sorted[sorted.size / 2]) / 2.0
    end

    def self.crossed?(side:, price:, previous:, current:, lower: nil, upper: nil, buffer: nil)
      return false if previous.nil? || current.nil?
      tolerance = buffer || price.to_d * BigDecimal("0.001")
      boundary = side == "resistance" ? (upper || price).to_d + tolerance.to_d : (lower || price).to_d - tolerance.to_d
      side == "resistance" ? previous.to_d <= boundary && current.to_d > boundary : previous.to_d >= boundary && current.to_d < boundary
    end
  end
end
