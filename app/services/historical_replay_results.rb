# Outcomes are deliberately evaluated after every detection decision is frozen.
class HistoricalReplayResults
  MINUTE_HORIZONS = [15, 30, 60].freeze
  DAILY_HORIZONS = [1, 3, 5, 10].freeze
  COSTS = [0.0, 0.05, 0.10, 0.20].freeze # total round-trip percentage points

  def initialize(events:, minutes:, days:, through:)
    @events, @minutes, @days, @through = events, minutes, days, through
    @minute_index = minutes.index_by(&:time)
  end

  def call
    @events.each do |event|
      event[:results] = (event[:daily] ? DAILY_HORIZONS : MINUTE_HORIZONS).to_h do |h|
        [h, event[:daily] ? daily_result(event, h) : minute_result(event, h)]
      end
    end
    HistoricalStrategyReplay::LABELS.flat_map do |family, label|
      events = @events.select { |e| e[:family] == family }
      daily = family.start_with?('daily_', 'level_')
      horizons = daily ? DAILY_HORIZONS : MINUTE_HORIZONS
      horizons.map do |h|
        selected = without_overlap(events, h, daily: daily)
        stats = summarize(selected, h)
        stats.merge(family: family, label: label, daily: daily, horizon: h, registered: events.size,
          selected: selected.size, overlapping: events.size - selected.size,
          cohorts: %w[with_trend countertrend near_strong_zone].to_h do |key|
            cohort = selected.select { |e| key == 'near_strong_zone' ? e.dig(:context, :near_strong_zone) : e.dig(:context, :alignment) == key }
            [key, summarize(cohort, h)]
          end)
      end
    end
  end

  def self.summarize_values(values, days)
    losses = values.select(&:negative?).sum.abs
    mean = values.any? ? values.sum / values.size : nil
    { used: values.size, positive: values.count(&:positive?), mean: mean,
      median: values.any? ? MarketIndicatorsMedian.call(values) : nil,
      win_rate: values.any? ? values.count(&:positive?) * 100.0 / values.size : nil,
      profit_factor: losses.positive? ? values.select(&:positive?).sum / losses : nil,
      ci95_by_day: bootstrap(values, days),
      costs: COSTS.to_h do |cost|
        net = values.map { |v| v - cost }
        net_loss = net.select(&:negative?).sum.abs
        [cost, { mean: mean && mean - cost, positive: net.count(&:positive?),
          profit_factor: net_loss.positive? ? net.select(&:positive?).sum / net_loss : nil }]
      end }
  end

  # Resample days as blocks rather than pretend all intraday observations are
  # independent. Intervals with fewer than two observed days stay unknown.
  def self.bootstrap(values, dates)
    groups = values.zip(dates).group_by(&:last).values.map { |pairs| pairs.map(&:first) }
    return if groups.size < 2
    random = Random.new(20261016)
    means = 2000.times.map do
      sample = Array.new(groups.size) { groups[random.rand(groups.size)] }.flatten
      sample.sum / sample.size
    end.sort
    [means[49], means[1949]]
  end

  class MarketIndicatorsMedian
    def self.call(values)
      sorted = values.sort
      (sorted[(sorted.size - 1) / 2] + sorted[sorted.size / 2]) / 2.0
    end
  end

  private

  def minute_result(event, horizon)
    at = Time.iso8601(event[:at])
    entry_at = HintLifecycle.next_minute(at)
    finish = entry_at + horizon.minutes
    return { status: 'censored', entry_at: entry_at.iso8601 } if finish + 35.seconds > @through
    bars = Array.new(horizon) { |i| @minute_index[entry_at + i.minutes] }
    return { status: 'missing_minutes', entry_at: entry_at.iso8601 } if bars.any?(&:nil?)
    return { status: 'session_boundary', entry_at: entry_at.iso8601 } unless bars.all? { |b| b.time.in_time_zone.to_date == entry_at.in_time_zone.to_date }
    return { status: 'invalid_price' } unless bars.all? { |b| Detectors::Reversal.valid_bar?(b) }
    return { status: 'undirected' } unless %w[up down].include?(event[:direction])
    signed_marks(bars, entry: bars.first.open_price, up: event[:direction] == 'up', entry_at: entry_at)
  end

  def daily_result(event, horizon)
    at = Time.iso8601(event[:at])
    available = @days.select { |b| b.time > at }
    return { status: 'censored' } if available.size < horizon
    bars = available.first(horizon)
    return { status: 'missing_days' } if bars.each_cons(2).any? { |a,b| b.time - a.time > 4.days }
    return { status: 'invalid_price' } unless bars.all? { |b| DailyRetestResearch.valid_bar?(b) }
    up = event[:direction] == 'up'
    entry = bars.first.open
    stop = event[:stop]&.to_d
    return { status: 'missed_stop', entry_at: bars.first.time.iso8601 } if stop && (up ? entry <= stop : entry >= stop)
    marks = signed_marks(bars, entry: entry, up: up, entry_at: bars.first.time)
    if stop
      sign = up ? 1 : -1
      target = entry + sign * 2 * (entry - stop).abs
      exit = DailyRetestOutcome.exit_for(bars, stop: stop, target: target, up: up)
      change = ->(price) { ((price / entry - 1) * 100 * sign).to_f }
      marks.merge!(price_change: marks[:change], change: change.call(exit[:worst]),
        trade_best: change.call(exit[:best]), ambiguous: exit[:reason] == 'ambiguous', exit_reason: exit[:reason],
        exit_at: exit[:time].iso8601, stop: stop.to_s, target: target.to_s)
    end
    marks
  end

  def signed_marks(bars, entry:, up:, entry_at:)
    sign = up ? 1 : -1
    change = ->(price) { ((price / entry - 1) * 100 * sign).to_f }
    low_field, high_field, close_field = bars.first.respond_to?(:open_price) ? %i[low_price high_price close_price] : %i[low high close]
    marks = bars.flat_map { |b| [change.call(b.public_send(low_field)), change.call(b.public_send(high_field))] }
    { status: 'measured', entry_at: entry_at.iso8601, entry_price: entry.to_s,
      end_at: bars.last.time.iso8601, change: change.call(bars.last.public_send(close_field)),
      favorable: [marks.max, 0].max, adverse: [marks.min, 0].min }
  end

  # Selection never inspects whether a trade will have a complete or good outcome.
  def without_overlap(events, horizon, daily:)
    until_at = nil
    events.sort_by { |e| [e[:at], e[:id]] }.select do |event|
      decision = Time.iso8601(event[:at])
      entry = daily ? @days.find { |b| b.time > decision }&.time : HintLifecycle.next_minute(decision)
      entry ||= decision
      next false if until_at && entry < until_at
      until_at = if daily
        start = @days.index { |b| b.time == entry }
        start && @days[start + horizon] ? @days[start + horizon].time : @through + 1.day
      else
        entry + horizon.minutes
      end
      true
    end
  end

  def summarize(events, horizon)
    marks = events.map { |e| [e, e[:results][horizon]] }
    used = marks.select { |_, r| r[:status] == 'measured' }
    values = used.map { |_, r| r[:change] }
    days = used.map { |e, _| Time.iso8601(e[:at]).in_time_zone.to_date }
    self.class.summarize_values(values, days).merge(
      statuses: marks.group_by { |_, r| r[:status] }.transform_values(&:size),
      observed_days: days.uniq.size, ambiguous: used.count { |_, r| r[:ambiguous] },
      favorable_mean: used.any? ? used.sum { |_, r| r[:favorable] } / used.size : nil,
      adverse_mean: used.any? ? used.sum { |_, r| r[:adverse] } / used.size : nil)
  end
end
