module Detectors
  class Volume
    BASELINE_SIZE = 20
    def self.evaluate(current:, history:, multiplier:, minimum:, canonical: false)
      return unless history.length == BASELINE_SIZE && current.complete
      if canonical
        return unless history.all? { |bar| bar.is_a?(ReversalMinute) && Detectors::Reversal.valid_bar?(bar) && bar.volume >= 0 }
      else
        return unless history.all? { |bar| bar.complete && bar.session == current.session }
      end
      return unless (history + [current]).each_cons(2).all? { |a, b| (b.time - a.time).to_i == 60 }
      volumes = history.map(&:volume).sort
      baseline = (volumes[9] + volumes[10]) / 2.0
      total = current.buy + current.sell + current.unknown
      return unless baseline.positive? && total >= minimum && total >= baseline * multiplier
      known = current.buy + current.sell
      { baseline_source: canonical ? "completed_ohlcv" : "stream_session", volume: total, baseline: baseline, ratio: (total / baseline).round(2), buy: current.buy, sell: current.sell, unknown: current.unknown, buy_percent: known.positive? ? (current.buy * 100.0 / known).round(1) : nil }
    end
  end
end
