# Prospective snapshots only. Zones are daily/weekly; minutes describe the trigger.
class TechnicalContext
  VERSION = 1
  PRIMARY_HORIZON = 30
  NEAR_ATR = 0.5
  TREND_LABELS = { 'up' => 'Восходящий', 'down' => 'Нисходящий', 'range' => 'Боковой / смешанный', 'unknown' => 'Недостаточно истории' }.freeze
  ALIGNMENT_LABELS = { 'with_trend' => 'По дневному тренду', 'countertrend' => 'Против дневного тренда', 'range' => 'В боковом / смешанном контексте', 'unknown' => 'Тренд или направление не определены' }.freeze
  LOCATION_LABELS = { 'inside_zone' => 'Внутри сильной зоны', 'near_support' => 'У сильной поддержки',
    'near_resistance' => 'У сильного сопротивления', 'near_both' => 'Между близкими сильными зонами',
    'away' => 'Вдали от известных сильных зон', 'unknown' => 'Недостаточно зон или ATR' }.freeze
  SHAPE_LABELS = { 'small_body' => 'Малое тело относительно диапазона', 'upper_wick' => 'Длинная верхняя тень',
    'lower_wick' => 'Длинная нижняя тень', 'strong_up_close' => 'Рост с закрытием у максимума',
    'strong_down_close' => 'Снижение с закрытием у минимума', 'mixed' => 'Смешанная свеча', 'flat' => 'Нулевой диапазон' }.freeze

  def self.price_for(signal)
    d = signal.details
    value = if signal.kind == 'volume'
      (d['bursts']&.first || d)['close_price']
    else
      d['price'] || d['entry_price'] || d['close'] || d['decision_price']
    end
    number(value)
  end

  def self.number(value)
    n = BigDecimal(value.to_s, exception: false)
    n if n&.finite? && n.positive?
  end

  def self.direction_for(signal)
    d = signal.details
    return d['direction'] if d['direction'].in?(%w[up down])
    if signal.kind == 'volume'
      b = d['bursts']&.first || d
      opening, closing = number(b['open_price']), number(b['close_price'])
      return unless opening && closing && opening != closing
      return closing > opening ? 'up' : 'down'
    end
    { 'resistance' => 'up', 'support' => 'down' }[d['side']] unless signal.kind == 'failed_breakout'
  end

  def self.capture(signal, now: Time.current)
    price = price_for(signal)
    return unless price
    instrument = signal.instrument
    day_cutoff = now.in_time_zone.beginning_of_day
    days = instrument.candles.where(timeframe: 'day', data_source: 't_invest')
      .where('time < ? AND time <= ?', day_cutoff, now - 1.day).order(time: :desc).limit(260).to_a.reverse
    weeks = instrument.candles.where(timeframe: 'week', data_source: 't_invest').where('time <= ?', now - 7.days).order(time: :desc).limit(130).to_a.reverse
    # A corrupt bar invalidates its prefix rather than being silently skipped.
    daily = trend(days, 'day')
    weekly = trend(weeks, 'week')
    atr = days.all? { |bar| DailyRetestResearch.valid_bar?(bar) } ? MarketIndicators.atr(days).last : nil
    atr = nil unless atr&.finite? && atr.positive?
    direction = direction_for(signal)
    levels = instrument.price_levels.active.where(status: 'confirmed', timeframe: %w[day week])
      .where('created_at <= ? AND updated_at <= ?', now, now).to_a
      .select { |level| !level.assessment['as_of'] || completed_level?(level.assessment['as_of'], level.timeframe, now) }
    strength = LevelStrength.new(levels)
    zones = levels.filter_map do |level|
      next unless strength.call(level).grade == 3
      as_of = level.assessment['as_of']
      distance = [level.lower_bound - price, price - level.upper_bound, 0].max.to_f
      { 'id' => level.id, 'timeframe' => level.timeframe, 'side' => level.side,
        'lower' => level.lower_bound.to_s, 'upper' => level.upper_bound.to_s, 'grade' => 3,
        'score' => level.assessment['score'], 'as_of' => as_of, 'distance_percent' => distance / price.to_f * 100,
        'distance_atr' => atr ? distance / atr : nil }
    end
    support = zones.select { |z| z['side'] == 'support' && z['lower'].to_d <= price }.min_by { |z| [z['distance_percent'], z['id']] }
    resistance = zones.select { |z| z['side'] == 'resistance' && z['upper'].to_d >= price }.min_by { |z| [z['distance_percent'], z['id']] }
    near = atr ? zones.select { |z| z['distance_atr'] <= NEAR_ATR } : []
    location = if !atr || zones.empty?
      'unknown'
    elsif zones.any? { |z| price.between?(z['lower'].to_d, z['upper'].to_d) }
      'inside_zone'
    elsif near.map { |z| z['side'] }.uniq.size == 2
      'near_both'
    elsif near.any?
      near.first['side'] == 'support' ? 'near_support' : 'near_resistance'
    else
      'away'
    end
    alignment = if !direction || daily['direction'] == 'unknown'
      'unknown'
    elsif daily['direction'] == 'range'
      'range'
    else
      direction == daily['direction'] ? 'with_trend' : 'countertrend'
    end
    opposing = direction == 'up' ? resistance : direction == 'down' ? support : nil
    invalidation = number(signal.details['invalidation'] || signal.details['stop'])
    if !invalidation && signal.kind == 'reversal' && number(signal.details['extreme']) && number(signal.details['volatility']) && direction
      invalidation = signal.details['extreme'].to_d + (direction == 'up' ? -1 : 1) * signal.details['volatility'].to_d * BigDecimal('0.1')
    end
    risk = invalidation && direction ? (price - invalidation).to_f * (direction == 'up' ? 1 : -1) : nil
    risk = nil unless risk&.positive?
    room = opposing && opposing['distance_percent'] / 100 * price.to_f
    { 'version' => VERSION, 'captured_at' => now.iso8601, 'price' => price.to_s, 'direction' => direction,
      'primary_horizon' => PRIMARY_HORIZON, 'daily' => daily, 'weekly' => weekly, 'daily_atr' => atr,
      'alignment' => alignment, 'location' => location, 'near_atr_threshold' => NEAR_ATR,
      'strong_zones_count' => zones.size, 'support' => support, 'resistance' => resistance,
      'opposing_room_percent' => opposing && opposing['distance_percent'], 'opposing_room_atr' => opposing && opposing['distance_atr'],
      'invalidation' => invalidation&.to_s, 'risk_percent' => risk && risk / price.to_f * 100,
      'room_risk' => room && risk ? room / risk : nil, 'candle' => candle_shape(signal, atr) }
  end

  def self.completed_level?(as_of, timeframe, now)
    time = Time.iso8601(as_of)
    timeframe == 'week' ? time + 7.days <= now : time < now.in_time_zone.beginning_of_day && time + 1.day <= now
  rescue ArgumentError, TypeError
    false
  end

  def self.trend(bars, timeframe)
    return { 'direction' => 'unknown', 'bars' => bars.size } if bars.empty? || bars.any? { |b| !DailyRetestResearch.valid_bar?(b) }
    context = MarketIndicators.context(bars, timeframe)
    fast, slow = timeframe == 'week' ? [20, 40] : [20, 50]
    ema_fast, ema_slow = context['ema'].values_at(fast, slow)
    slope = context['slope_5'][fast]
    direction = if !ema_fast || !ema_slow || !slope
      'unknown'
    elsif context['close'] > ema_fast && ema_fast > ema_slow && slope.positive?
      'up'
    elsif context['close'] < ema_fast && ema_fast < ema_slow && slope.negative?
      'down'
    else
      'range'
    end
    context.merge('direction' => direction, 'bars' => bars.size)
  end

  def self.candle_shape(signal, atr)
    return unless signal.kind == 'volume'
    b = signal.details['bursts']&.first || signal.details
    opening, high, low, closing = %w[open_price high_price low_price close_price].map { |key| number(b[key]) }
    return unless [opening, high, low, closing].all? && high >= [opening, closing, low].max && low <= [opening, closing].min
    range = (high - low).to_f
    return { 'shape' => 'flat', 'range_atr' => atr ? 0.0 : nil } if range.zero?
    body = (closing - opening).abs.to_f / range
    upper = (high - [opening, closing].max).to_f / range
    lower = ([opening, closing].min - low).to_f / range
    position = (closing - low).to_f / range
    shape = if upper >= 0.5 then 'upper_wick'
    elsif lower >= 0.5 then 'lower_wick'
    elsif body <= 0.25 then 'small_body'
    elsif closing > opening && position >= 0.75 then 'strong_up_close'
    elsif closing < opening && position <= 0.25 then 'strong_down_close'
    else 'mixed'
    end
    { 'shape' => shape, 'body_fraction' => body, 'upper_wick_fraction' => upper, 'lower_wick_fraction' => lower,
      'close_position' => position, 'range_atr' => atr ? range / atr : nil, 'relative_volume' => b['ratio'] }
  end
end
