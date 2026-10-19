# Research replay only. All inputs advance by their availability time; nothing
# in this class reads the database or consults future bars to create a signal.
class HistoricalStrategyReplay
  VERSION = 1
  MINUTE_DELAY = 95.seconds
  LABELS = {
    'volume_raw' => 'Объём: все эпизоды', 'volume_visible' => 'Объём: ценовой и сезонный фильтры',
    'volume_hold' => 'Объём: удержание подтверждено',
    'reversal' => 'Разворот: кандидат', 'reversal_confirmation' => 'Разворот: подтверждение',
    'context' => 'Длительный разворот: кандидат', 'context_confirmation' => 'Длительный разворот: подтверждение',
    'structure_v1' => 'Экстремум и ретест', 'pullback_structure_v1' => 'Отскок, откат и пробой',
    'crossing_close_proxy' => 'Пересечение сильной зоны: минутные закрытия',
    'false_breakout_v1' => 'Ложный пробой: источник по минутным закрытиям',
    'level_confirmed' => 'Уровни: закрытие за зоной', 'level_retest' => 'Уровни: ретест',
    'level_held_breakout' => 'Уровни: удержание', 'level_failed_breakout' => 'Уровни: возврат в зону',
    'daily_retest_v1' => 'Дневной пробой и ретест', 'daily_support_bounce_v1' => 'Дневной отскок от поддержки',
    'legacy_shock' => 'Архив: резкий шок и отскок',
    'directional_v1' => 'Архив: минутная идея v1, подтверждение',
    'directional_v2' => 'Архив: минутная идея v2, подтверждение'
  }.freeze

  # Minimal in-memory models let the production state transitions run unchanged.
  class Record
    attr_accessor :id, :instrument, :kind, :experiment, :event_key, :occurred_at,
      :created_at, :confirmed_at, :reversal_status, :details, :title, :research_only,
      :last_occurred_at, :now
    def initialize(**attrs)
      @details = {}
      assign_attributes(attrs)
    end
    def assign_attributes(attrs)
      attrs.each { |key, value| public_send("#{key}=", key.to_sym == :details ? value.deep_stringify_keys : value) }
      self
    end
    def update!(attrs = {}, **keywords)
      assign_attributes(attrs.merge(keywords))
      self.confirmed_at ||= now if reversal_status == 'confirmed'
      self
    end
  end

  class Scope
    include Enumerable
    def initialize(rows) = @rows = rows
    def each(&block) = @rows.each(&block)
    def to_a = @rows.dup
    def active = self.class.new(@rows.select(&:active?))
    def where(conditions, *args)
      selected = if conditions.is_a?(Hash)
        @rows.select { |row| conditions.all? { |key, value| Array(value).include?(row.public_send(key)) } }
      elsif conditions == 'time < ?'
        @rows.select { |row| row.time < args.first }
      else
        raise ArgumentError, "Unsupported replay query: #{conditions}"
      end
      self.class.new(selected)
    end
    def order(**fields)
      key, dir = fields.first
      values = @rows.sort_by { |row| row.public_send(key) }
      self.class.new(dir == :desc ? values.reverse : values)
    end
    def limit(n) = self.class.new(@rows.first(n))
  end

  class Level
    attr_accessor :id, :instrument_id, :source, :timeframe, :side, :price, :lower_price,
      :upper_price, :atr, :status, :touches, :assessment, :active, :evaluated_at,
      :created_at, :last_alert_at, :breakout
    def initialize(**attrs)
      @assessment, @breakout, @active = {}, {}, true
      update!(**attrs)
    end
    def update!(attrs = {}, **keywords)
      attrs.merge(keywords).each do |key, value|
        value = value.to_d if %i[price lower_price upper_price atr].include?(key) && value
        value = value.deep_stringify_keys if %i[assessment breakout].include?(key)
        public_send("#{key}=", value)
      end
      self
    end
    def active? = active
    def lower_bound = lower_price || price
    def upper_bound = upper_price || price
    def breakout_buffer = atr&.positive? ? atr * BigDecimal('0.1') : price * BigDecimal('0.001')
    def crossed?(previous, current)
      Detectors::Levels.crossed?(side: side, price: price, previous: previous, current: current,
        lower: lower_bound, upper: upper_bound, buffer: breakout_buffer)
    end
  end

  class LevelPool < Scope
    def initialize(rows, owner: nil)
      super(rows)
      @owner = owner
    end
    def create!(attrs = {}, **keywords)
      row = Level.new(**attrs.merge(keywords), id: @rows.size + 1, instrument_id: @owner.id, created_at: @owner.now)
      @rows << row
      row
    end
  end

  class EventPool
    attr_reader :rows
    def initialize(owner)
      @owner, @rows = owner, []
    end
    def transaction = yield
    def create!(**attrs)
      row = Record.new(id: @rows.size + 1, instrument: @owner, now: @owner.now,
        created_at: @owner.now, **attrs)
      @rows << row
      @owner.on_create(row)
      row
    end
    def find_by(**attrs) = @rows.find { |row| attrs.all? { |k,v| row.public_send(k) == v } }
    def find_or_create_by!(**attrs)
      row = find_by(**attrs)
      return row if row
      row = Record.new(id: @rows.size + 1, instrument: @owner, now: @owner.now, created_at: @owner.now, **attrs)
      yield row
      @rows << row
      @owner.on_create(row)
      row
    end
  end

  class InstrumentState
    attr_reader :id, :signals, :price_levels, :replay
    attr_accessor :now, :minutes
    def initialize(id, replay)
      @id, @replay, @minutes = id, replay, []
      @signals = EventPool.new(self)
      @price_levels = LevelPool.new([], owner: self)
    end
    def with_lock = yield
    def enabled? = true
    def breakout_enabled? = true
    def reversal_minutes = Scope.new(minutes)
    def on_create(record) = replay.on_create(record)
  end

  class Lifecycle < LevelLifecycle
    def self.emit(instrument, level, candle, kind, title, state, context:)
      return unless state['strength_grade'] == 3
      up = state['side'] == 'resistance'
      up = !up if kind == 'failed_breakout'
      instrument.replay.emit("level_#{kind}", instrument.now, up ? 'up' : 'down',
        daily: true, details: { level_id: level.id, lower: state['lower'], upper: state['upper'],
          frame: level.timeframe, candle_time: candle.time.iso8601, level_as_of: level.assessment['as_of'] })
    end
  end

  attr_reader :events, :diagnostics, :states

  def initialize(instrument:, minutes:, days:, weeks:, volume_samples: [], through:, include_legacy: true)
    @settings = instrument
    @minutes = minutes.select { |b| b.time + MINUTE_DELAY <= through }.sort_by(&:time)
    @days = days.select { |b| b.time + 1.day + 1.second <= through && b.data_source == 't_invest' }.sort_by(&:time)
    @weeks = weeks.select { |b| b.time + 7.days + 1.second <= through && b.data_source == 't_invest' }.sort_by(&:time)
    @volume_samples = volume_samples
    @through, @include_legacy = through, include_legacy
    @events, @diagnostics = [], Hash.new(0)
    @instrument = InstrumentState.new(instrument.id, self)
    @level_history = { 'day' => [], 'week' => [] }
    @research_day = DailyRetestLevels.new(instrument.id, 'day')
    @research_week = DailyRetestLevels.new(instrument.id, 'week')
    @waiting_weeks, @research_weeks, @research_days = [], [], []
    @daily_state = { 'pending' => [], 'cooldown' => 0 }
    @bounce_state = { 'cooldown' => 0 }
    @bounce = nil
    @buffer, @seen_minutes, @reversals, @studies, @volume_trials = [], {}, [], [], []
    @run_length = 0
    @last_candidates, @episodes, @legacy_used = {}, {}, {}
    @states = []
  end

  def run
    timeline = @days.map { |b| [b.time + 1.day + 1.second, 1, :day, b] } +
      @weeks.map { |b| [b.time + 7.days + 1.second, 0, :week, b] } +
      @minutes.map { |b| [b.time + MINUTE_DELAY, 2, :minute, b] }
    timeline.sort_by { |time, priority, _, _| [time, priority] }.each do |time, _, type, bar|
      @now = @instrument.now = time
      if type == :minute
        advance_minute(bar)
      else
        advance_daily(bar, type.to_s)
      end
    end
    @now = @instrument.now = @through
    @reversals.select { |r| r.reversal_status == 'possible' }.each do |r|
      r.update!(reversal_status: 'expired') if @through > r.occurred_at + 12.minutes
    end
    @states = @instrument.signals.rows.map do |r|
      { id: r.id, kind: r.kind, experiment: r.experiment, at: r.created_at.iso8601,
        status: r.reversal_status, confirmed_at: r.confirmed_at&.iso8601 }
    end
    levels = @instrument.price_levels.active.to_a
    strength = LevelStrength.new(levels)
    @diagnostics['final_active_levels'] = levels.size
    @diagnostics['final_strong_levels'] = levels.count { |l| strength.call(l).grade == 3 }
    self
  end

  def emit(family, at, direction, daily: false, stop: nil, details: {}, parent: nil)
    event = { id: @events.size + 1, family: family, at: at.iso8601, direction: direction,
      daily: daily, stop: stop&.to_s, details: details.deep_stringify_keys, parent: parent,
      context: context_for(direction, daily: daily, price: details[:decision_price] || details[:price] || details[:entry_price]) }
    @events << event
    event
  end

  def on_create(record)
    if record.kind == 'reversal_structure'
      # ReversalResearch uses Time.current only for this metadata field. Replace
      # that wall clock with the historical processing clock before freezing it.
      record.details['decision_at'] = @now.iso8601
      emit('structure_v1', @now, record.details.fetch('direction'), parent: record.details['parent_signal_id'], details: record.details)
    end
  end

  private

  def context_for(direction, daily:, price: nil)
    days = @level_history['day'].last(260)
    daily = TechnicalContext.trend(days, 'day')['direction']
    atr = MarketIndicators.atr(days).last
    price = price&.to_d || (daily ? days.last&.close : @seen_minutes.values.last&.close_price)
    levels = @instrument.price_levels.active.to_a
    strength = LevelStrength.new(levels)
    near = price && atr&.positive? && levels.any? do |level|
      strength.call(level).grade == 3 && [level.lower_bound - price, price - level.upper_bound, 0].max <= atr * 0.5
    end
    { daily_trend: daily, near_strong_zone: !!near, alignment: daily == 'down' ? (direction == 'down' ? 'with_trend' : 'countertrend') :
      daily == 'up' ? (direction == 'up' ? 'with_trend' : 'countertrend') : daily }
  end

  def advance_daily(bar, frame)
    # Only the visible prefix is passed to the production lifecycle and builder.
    @level_history[frame] << bar
    Lifecycle.call(instrument: @instrument, timeframe: frame, candles: @level_history[frame])
    LevelBuilder.call(instrument: @instrument, timeframe: frame, candles: @level_history[frame])
    if frame == 'week'
      @waiting_weeks << bar
      return
    end
    while @waiting_weeks.first && @waiting_weeks.first.time + 7.days <= bar.time
      week = @waiting_weeks.shift
      @research_week.push(week)
      @research_weeks << week
    end
    previous = @research_days.last
    atr = MarketIndicators.atr(@research_days).last
    if previous && bar.time - previous.time <= 4.days && DailyRetestResearch.valid_bar?(bar)
      strong = @research_day.strong + @research_week.strong
      advance_retest(bar, previous, atr, strong)
      advance_bounce(bar, previous, atr, strong)
    else
      @daily_state['pending'] = []
      @bounce = nil
    end
    @research_days << bar
    @research_day.push(bar)
  end

  def advance_retest(bar, previous, atr, strong)
    blocked = @daily_state['cooldown'].positive?
    @daily_state['cooldown'] = [@daily_state['cooldown'] - 1, 0].max
    advanced = @daily_state['pending'].map { |s| DailyRetestSetup.advance(s, bar) }
    confirmed = advanced.select { |s| s['status'] == 'confirmed' }
    advanced.reject { |s| s['status'] == 'possible' }.each { |s| @diagnostics["daily_retest_#{s['status']}"] += 1 }
    if confirmed.any? && confirmed.map { |s| s['direction'] }.uniq.size == 1 && !blocked
      up = confirmed.first['direction'] == 'up'
      stop = up ? confirmed.map { |s| s['stop'].to_d }.min : confirmed.map { |s| s['stop'].to_d }.max
      emit('daily_retest_v1', @now, up ? 'up' : 'down', daily: true, stop: stop,
        details: { zones: confirmed, decision_price: bar.close.to_s, decision_bar: bar.time.iso8601 })
      @daily_state['cooldown'] = 10
    end
    @daily_state['pending'] = advanced.select { |s| s['status'] == 'possible' }
    strong.each do |level|
      setup = DailyRetestSetup.start(level, previous: previous, bar: bar, atr: atr)
      if setup
        @daily_state['pending'] << setup
        @diagnostics['daily_retest_candidates'] += 1
      end
    end
  end

  def advance_bounce(bar, previous, atr, strong)
    blocked = @bounce_state['cooldown'].positive?
    @bounce_state['cooldown'] = [@bounce_state['cooldown'] - 1, 0].max
    if @bounce
      @bounce = DailySupportBounceSetup.advance(@bounce, bar)
      if @bounce['status'] != 'possible'
        @diagnostics["daily_bounce_#{@bounce['status']}"] += 1
        if @bounce['status'] == 'confirmed'
          emit('daily_support_bounce_v1', @now, 'up', daily: true, stop: @bounce['stop'],
            details: { setup: @bounce, decision_bar: bar.time.iso8601,
              daily_trend: TechnicalContext.trend(@research_days + [bar], 'day')['direction'] })
          @bounce_state['cooldown'] = 10
        end
        @bounce = nil
      end
      return
    end
    return if blocked
    weekly = MarketIndicators.context(@research_weeks, 'week')
    candidates = strong.filter_map { |z| DailySupportBounceSetup.start(z, previous: previous, bar: bar, atr: atr, weekly: weekly) }
    @bounce = candidates.min_by { |s| [(bar.low - s['lower'].to_d).abs, s['frame'] == 'week' ? 0 : 1, -s['score'].to_f] }
    @diagnostics['daily_bounce_candidates'] += 1 if @bounce
  end

  def advance_minute(bar)
    unless Detectors::Reversal.valid_bar?(bar)
      @diagnostics['invalid_minutes'] += 1
      @buffer = []
      @run_length = 0
      return
    end
    if @buffer.last && (bar.time - @buffer.last.time != 60 || bar.time.in_time_zone.to_date != @buffer.last.time.in_time_zone.to_date)
      @diagnostics['minute_gaps_or_session_boundaries'] += 1
      @diagnostics['longest_contiguous_run'] = [@diagnostics['longest_contiguous_run'], @buffer.size].max
      @buffer = []
      @run_length = 0
    end
    @seen_minutes[bar.time] = bar
    @instrument.minutes << bar
    advance_volume_trials
    advance_reversals(bar)
    advance_studies(bar)
    advance_legacy(bar) if @include_legacy
    volume(bar)
    crossings(bar)
    @buffer << bar
    @run_length += 1
    @buffer.shift if @buffer.size > ReversalHistory::LOOKBACK
    @diagnostics['eligible_short_reversal_minutes'] += 1 if @buffer.size >= 28
    @diagnostics['eligible_context_minutes'] += 1 if @buffer.size >= 83
    detect_reversals(bar) if @buffer.size >= 28
    legacy_candidates(bar) if @include_legacy
    @diagnostics['minutes_processed'] += 1
    @diagnostics['longest_contiguous_run'] = [@diagnostics['longest_contiguous_run'], @run_length].max
    @previous_minute = bar
  end

  def detect_reversals(bar)
    [nil, 'context_5m_v3'].each do |experiment|
      next if @reversals.any? { |s| s.experiment == experiment && s.reversal_status == 'possible' }
      d = Detectors::Reversal.evaluate(bars: @buffer, aggregated_context: !!experiment)
      next unless d
      key = [experiment, d[:direction]]
      next if @last_candidates[key] && bar.time + 60 - @last_candidates[key] < ReversalTracker::COOLDOWN
      @last_candidates[key] = bar.time + 60
      d[:structure_checked_at] = bar.time.iso8601
      source = @instrument.signals.create!(kind: 'reversal', experiment: experiment,
        occurred_at: bar.time + 60, reversal_status: 'possible', details: d)
      @reversals << source
      family = experiment ? 'context' : 'reversal'
      emit(family, @now, d[:direction], parent: source.id, details: d)
      unless experiment
        @studies << { source: source, experiment: TechnicalStudies::STRUCTURE, registered: @now,
          checked: bar.time, state: { 'peak' => d[:rebound_boundary].to_s, 'previous_close' => d[:entry_price].to_s } }
      end
    end
  end

  def advance_reversals(bar)
    @reversals.each do |source|
      source.now = @now
      if source.reversal_status == 'possible'
        previous = Time.iso8601(source.details.fetch('last_checked_at'))
        if bar.time == previous + 60
          ReversalTracker.advance(source, bar)
          if source.reversal_status == 'confirmed'
            emit(source.experiment ? 'context_confirmation' : 'reversal_confirmation', @now,
              source.details['direction'], parent: source.id, details: source.details)
          end
        elsif @now > source.occurred_at + 12.minutes
          source.update!(reversal_status: 'expired')
        end
      end
      next if source.experiment || source.details.fetch('structure_status', 'pending') != 'pending'
      previous = Time.iso8601(source.details['structure_checked_at'])
      if bar.time == previous + 60
        ReversalResearch.advance(source, bar)
      elsif @now > source.occurred_at + 22.minutes
        source.update!(details: source.details.merge('structure_status' => 'expired'))
      end
    end
  end

  def advance_studies(bar)
    @studies.each do |study|
      next if study[:finished]
      deadline = study[:registered] + TechnicalStudies::WINDOWS.fetch(study[:experiment])
      if @now > deadline + 2.minutes || bar.time + 60 > deadline || bar.time.in_time_zone.to_date != study[:checked].in_time_zone.to_date
        study[:finished] = 'expired'
        next
      end
      next unless bar.time == study[:checked] + 60
      method = study[:experiment] == TechnicalStudies::STRUCTURE ? :advance_structure : :advance_false_breakout
      outcome = TechnicalStudies.public_send(method, study[:source], study[:state], bar)
      study[:checked] = bar.time
      next unless outcome
      study[:finished] = outcome
      if outcome == 'confirmed' && bar.time + 60 <= deadline
        source = study[:source]
        direction = study[:experiment] == TechnicalStudies::STRUCTURE ? source.details['direction'] : source.details['side'] == 'resistance' ? 'down' : 'up'
        emit(study[:experiment], @now, direction, parent: source.id, details: study[:state])
      end
    end
  end

  def volume(bar)
    history = @buffer.last(20)
    current = MarketMinute.new(time: bar.time, complete: true, session: 'historical', buy: 0, sell: 0,
      unknown: bar.volume, open_price: bar.open_price, high_price: bar.high_price, low_price: bar.low_price, close_price: bar.close_price)
    d = Detectors::Volume.evaluate(current: current, history: history, multiplier: @settings.volume_multiplier,
      minimum: @settings.minimum_volume, canonical: true)
    return unless d
    seasonal = seasonal_baseline(bar)
    quality = VolumeQuality.evaluate(instrument: @settings, bar: current, history: history, time_baseline: seasonal)
    research = @settings.volume_noise_filter? && !quality[:passed]
    @diagnostics["volume_filter_#{quality[:reason]}"] += 1
    return if @episodes[research] && @episodes[research] > bar.time + 60 - VolumeEpisode::WINDOW
    @episodes[research] = bar.time + 60
    direction = bar.close_price > bar.open_price ? 'up' : bar.close_price < bar.open_price ? 'down' : nil
    details = { ratio: d[:ratio], quality: quality, source_bar: bar.time.iso8601, price: bar.close_price.to_s }
    emit('volume_raw', @now, direction, details: details)
    emit('volume_visible', @now, direction, details: details) unless research
    change = ((bar.close_price / bar.open_price - 1) * 100).abs.to_f
    if change >= [0.15, quality[:threshold_percent]].max && quality[:atr_percent]
      @volume_trials << { reference: HintLifecycle.next_minute(@now), direction: direction,
        midpoint: (bar.open_price + bar.close_price) / 2, source_at: @now }
      @diagnostics['volume_hold_candidates'] += 1
    end
  end

  def seasonal_baseline(bar)
    date = bar.time.in_time_zone.to_date
    minute = bar.time.in_time_zone.hour * 60 + bar.time.in_time_zone.min
    samples = @volume_samples.select { |s| s.trading_date < date && s.trading_date >= date - 90 && s.minute_of_day == minute && s.day_type == MinuteVolumeSample.day_type(date) }
      .sort_by(&:trading_date).last(20)
    return { passed: nil, samples: samples.size, status: 'warming_up' } if samples.size < 10
    baseline = Detectors::Levels.median(samples.map(&:volume))
    { passed: baseline.positive? ? bar.volume >= baseline * @settings.volume_multiplier : nil, samples: samples.size,
      baseline: baseline, status: baseline.positive? ? 'ready' : 'zero_baseline' }
  end

  def advance_volume_trials
    @volume_trials.each do |trial|
      next if trial[:finished] || @now < trial[:reference] + 155.seconds
      if @now >= trial[:reference] + 5.minutes
        trial[:finished] = 'expired'
        next
      end
      bars = [@seen_minutes[trial[:reference]], @seen_minutes[trial[:reference] + 60]]
      next if bars.any?(&:nil?)
      sign = trial[:direction] == 'up' ? 1 : -1
      held = bars.all? { |b| (b.close_price - trial[:midpoint]) * sign > 0 } && (bars.last.close_price - bars.first.close_price) * sign >= 0
      trial[:finished] = held ? 'confirmed' : 'rejected'
      emit('volume_hold', @now, trial[:direction], details: { source_at: trial[:source_at].iso8601 }) if held
    end
  end

  def crossings(bar)
    previous = @previous_minute
    return unless previous && bar.time - previous.time == 60
    levels = @instrument.price_levels.active.to_a.select { |l| l.status == 'confirmed' }
    strength = LevelStrength.new(levels)
    crossed = levels.select { |l| strength.call(l).grade == 3 && (!l.last_alert_at || @now - l.last_alert_at >= 6.hours) && l.crossed?(previous.close_price, bar.close_price) }
    crossed.group_by(&:side).each_value do |same_side|
      groups = []
      same_side.sort_by(&:lower_bound).each do |level|
        group = groups.last
        if group && level.lower_bound <= group.map(&:upper_bound).max
          group << level
        else
          groups << [level]
        end
      end
      groups.each do |group|
        first = group.min_by(&:id)
        d = { 'side' => first.side, 'lower' => group.map(&:lower_bound).min.to_s,
          'upper' => group.map(&:upper_bound).max.to_s, 'buffer' => first.breakout_buffer.to_s,
          'price' => bar.close_price.to_s, 'strength_grade' => 3 }
        source = @instrument.signals.create!(kind: 'crossing', occurred_at: bar.time + 60, details: d)
        emit('crossing_close_proxy', @now, first.side == 'resistance' ? 'up' : 'down', parent: source.id, details: d)
        @studies << { source: source, experiment: TechnicalStudies::FALSE_BREAKOUT, registered: @now,
          checked: bar.time, state: { 'outside_extreme' => d['price'] } }
        group.each { |level| level.last_alert_at = @now }
      end
    end
  end

  def advance_legacy(bar)
    @instrument.signals.rows.select { |s| s.kind == 'directional_hint' && s.details['monitoring'] }.each do |hint|
      hint.now = @now
      previous = Time.iso8601(hint.details['last_checked_at'])
      if bar.time == previous + 60 && bar.time.in_time_zone.to_date == previous.in_time_zone.to_date
        was_confirmed = hint.confirmed_at
        service = hint.experiment == 'directional_v2' ? DirectionalHintResearch : DirectionalHints
        service.advance(hint, bar, now: @now)
        emit(hint.experiment, @now, hint.details['direction'], parent: hint.id, details: hint.details) if !was_confirmed && hint.confirmed_at
      end
      DirectionalHints.expire(hint, now: @now)
    end
  end

  def legacy_candidates(bar)
    controls = @instrument.signals.rows.select { |s| s.kind == 'directional_hint' && s.experiment == 'directional_v1' && s.details['monitoring'] }
    shock = Detectors::ShockReversal.evaluate(bars: @buffer)
    if shock && !@legacy_used[[:shock, shock[:extreme_at]]]
      @legacy_used[[:shock, shock[:extreme_at]]] = true
      emit('legacy_shock', @now, shock[:direction], details: shock)
      controls.select { |s| s.details['direction'] != shock[:direction] }.each do |hint|
        DirectionalHints.finish(hint, 'cancelled', 'Противоположный резкий отскок: конфликт сценариев', now: @now, bar: bar)
      end
      if controls.none? { |s| s.details['monitoring'] }
        DirectionalHints.create(@instrument, bar, shock, key: "shock:#{shock[:extreme_at]}", basis: 'shock', now: @now)
        return
      end
    end
    return if controls.any? { |s| s.details['monitoring'] }
    sources = @instrument.signals.rows.select { |s| %w[reversal crossing].include?(s.kind) && s.created_at >= @now - 5.minutes && !@legacy_used[s.id] }
    sources.each do |source|
      d = source.details
      if source.kind == 'reversal'
        next unless %w[possible confirmed].include?(source.reversal_status)
        config = d.symbolize_keys.slice(:direction, :extreme, :volatility, :rebound_boundary, :impulse_minutes, :relative_volume)
      else
        up = d['side'] == 'resistance'
        boundary = d.fetch(up ? 'upper' : 'lower').to_d
        buffer = d['buffer'].to_d
        next unless up ? bar.close_price >= boundary + buffer : bar.close_price <= boundary - buffer
        config = { direction: up ? 'up' : 'down', extreme: boundary.to_s, volatility: buffer.to_s,
          rebound_boundary: (boundary + (up ? buffer : -buffer)).to_s, invalidation: boundary.to_s }
      end
      config.merge!(source_experiment: source.experiment, source_signal_id: source.id, scenario: source.kind)
      hint = DirectionalHints.create(@instrument, bar, config, key: "source:#{source.id}", basis: 'source', now: @now)
      @legacy_used[source.id] = true if hint
      return if hint
    end
  end
end
