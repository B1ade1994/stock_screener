module Detectors
  class Volume
    BASELINE_SIZE = 20
    def self.evaluate(current:, history:, multiplier:, minimum:)
      return unless history.length == BASELINE_SIZE && current.complete
      return unless history.all? { |bar| bar.complete && bar.session == current.session }
      return unless (history + [current]).each_cons(2).all? { |a, b| (b.time - a.time).to_i == 60 }
      volumes = history.map { |b| b.buy + b.sell + b.unknown }.sort
      baseline = (volumes[9] + volumes[10]) / 2.0
      total = current.buy + current.sell + current.unknown
      return unless baseline.positive? && total >= minimum && total >= baseline * multiplier
      known = current.buy + current.sell
      { volume: total, baseline: baseline, ratio: (total / baseline).round(2), buy: current.buy, sell: current.sell, unknown: current.unknown, buy_percent: known.positive? ? (current.buy * 100.0 / known).round(1) : nil }
    end
  end
end
