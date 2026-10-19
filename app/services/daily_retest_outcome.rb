class DailyRetestOutcome
  HORIZONS = [1, 3, 5, 10].freeze

  # Live measurements use a whole candle that STARTS after registration. Never
  # claim an already-past opening fill when history arrived after that opening.
  def self.refresh(signal, days)
    d = signal.details.deep_dup
    window = days.select { |bar| bar.time > signal.confirmed_at }
    return if window.empty? || d['measurement_complete']
    unless DailyRetestResearch.valid_bar?(window.first)
      signal.update!(details: d.merge('measurement_complete' => true, 'measurement_error' => 'Некорректная свеча входа'))
      return
    end
    up = d['direction'] == 'up'
    sign = up ? 1 : -1
    entry = d['entry_price']&.to_d || window.first.open
    stop = d.fetch('stop').to_d
    if sign * (entry - stop) <= 0
      d.merge!('measurement_complete' => true, 'measurement_error' => 'Первая новая свеча открылась за стопом; вход пропущен')
      signal.update!(reversal_status: 'missed', details: d)
      return
    end
    target = entry + sign * 2 * (entry - stop).abs
    d.merge!('entry_at' => window.first.time.iso8601, 'entry_price' => entry.to_s, 'target' => target.to_s)
    d['outcomes'] ||= {}
    HORIZONS.each do |horizon|
      next if d['outcomes'].key?(horizon.to_s) || window.size < horizon
      bars = window.first(horizon)
      if bars.any? { |bar| !DailyRetestResearch.valid_bar?(bar) } || bars.each_cons(2).any? { |a, b| b.time - a.time > 4.days }
        d['outcomes'][horizon.to_s] = { 'status' => 'unavailable', 'reason' => 'Некорректные свечи или разрыв дневной истории больше четырёх суток' }
        next
      end
      change = ->(price) { ((price / entry - 1) * 100 * sign).to_f }
      marks = bars.flat_map { |bar| [change.call(bar.low), change.call(bar.high)] }
      exit = exit_for(bars, stop: stop, target: target, up: up)
      d['outcomes'][horizon.to_s] = { 'status' => 'measured', 'end_at' => bars.last.time.iso8601,
        'price_change' => change.call(bars.last.close), 'adverse' => [marks.min, 0].min,
        'favorable' => [marks.max, 0].max, 'trade_low' => change.call(exit[:worst]),
        'trade_high' => change.call(exit[:best]), 'exit_at' => exit[:time].iso8601,
        'exit_reason' => exit[:reason], 'ambiguous' => exit[:reason] == 'ambiguous' }
    end
    d['measurement_complete'] = d['outcomes'].key?('10')
    signal.update!(details: d)
  end

  def self.exit_for(bars, stop:, target:, up:)
    bars.each do |bar|
      stop_gap = up ? bar.open <= stop : bar.open >= stop
      target_gap = up ? bar.open >= target : bar.open <= target
      return { worst: bar.open, best: bar.open, time: bar.time, reason: 'stop_gap' } if stop_gap
      return { worst: target, best: target, time: bar.time, reason: 'target' } if target_gap
      stopped = up ? bar.low <= stop : bar.high >= stop
      reached = up ? bar.high >= target : bar.low <= target
      return { worst: stop, best: target, time: bar.time, reason: 'ambiguous' } if stopped && reached
      if stopped || reached
        price = stopped ? stop : target
        return { worst: price, best: price, time: bar.time, reason: stopped ? 'stop' : 'target' }
      end
    end
    { worst: bars.last.close, best: bars.last.close, time: bars.last.time, reason: 'timeout' }
  end
end
