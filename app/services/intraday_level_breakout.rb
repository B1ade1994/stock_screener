class IntradayLevelBreakout
  KIND = 'intraday_level_breakout'
  EXPERIMENT = 'intraday_level_breakout_v1'
  LOOKBACK = 15.minutes
  COOLDOWN = 6.hours
  Minute = Struct.new(:time, :open, :high, :low, :close, :volume, keyword_init: true)

  def self.call(instrument, now: Time.current, client: TInvest::Client.new)
    return unless DailyRetestResearch.eligible?(instrument)
    ready = instrument.with_lock do
      state = instrument.intraday_breakout_state
      enabled = instrument.enabled? && instrument.breakout_enabled? && !instrument.expired?
      if state.empty? || !enabled || state['enabled'] == false
        instrument.update!(intraday_breakout_state: { 'enabled' => enabled,
          'started_at' => now.iso8601, 'last_minute_at' => now.beginning_of_minute.iso8601 })
        false
      else
        true
      end
    end
    return unless ready

    through = (now - 95.seconds).beginning_of_minute
    from = [through - LOOKBACK, now.utc.beginning_of_day].max
    return if from > through
    # HTTP stays outside the row lock. The price is reloaded under lock below.
    minutes = client.minute_candles(instrument.uid, from: from, to: through + 1.minute)
      .map { |row| Minute.new(**row) }.select { |bar| bar.time.between?(from, through) }
      .uniq(&:time).sort_by(&:time)
    instrument.with_lock { process(instrument, minutes, now: now) }
  end

  def self.process(instrument, minutes, now:)
    state = instrument.intraday_breakout_state.deep_dup
    return unless instrument.enabled? && instrument.breakout_enabled? && !instrument.expired? && state['enabled']
    return unless minutes.any? && minutes.all? { |bar| DailyRetestResearch.valid_bar?(bar) }
    cursor = Time.iso8601(state.fetch('last_minute_at'))
    return if minutes.last.time <= cursor

    period = now.utc.beginning_of_day
    days = instrument.candles.where(timeframe: 'day', data_source: 't_invest')
      .where('time <= ?', period - 1.day).order(:time).to_a
    quote_at = instrument.last_trade_at
    fresh = quote_at && quote_at.between?(now - 2.minutes, now) && instrument.last_price&.positive?
    if fresh && days.size >= 15 && days.all? { |bar| DailyRetestResearch.valid_bar?(bar) } && period - days.last.time <= 4.days
      atr = MarketIndicators.atr(days).last
      started_at = Time.iso8601(state.fetch('started_at'))
      known_levels = instrument.price_levels.active.where(source: 'automatic', status: 'confirmed').to_a
      recent_ids = instrument.signals.where(kind: KIND, created_at: (now - COOLDOWN)..now)
        .pluck(:details).filter_map { |details| details.dig('setup', 'level_id')&.to_s }
      choices = []
      minutes.each_cons(3) do |previous, first, second|
        next unless previous.time >= period && previous.time > started_at && second.time > cursor
        next unless second.time >= now - 4.minutes && second.time + 1.minute <= now - 30.seconds
        next unless quote_at >= second.time + 1.minute
        levels = known_levels.select { |level| level.created_at <= previous.time && IntradaySupportBounce.completed_level?(level, previous.time) }
        strength = LevelStrength.new(levels)
        levels.each do |level|
          next unless strength.call(level).grade == 3
          next if recent_ids.include?(level.id.to_s)
          setup = LevelBreakoutSetup.start(level, levels: levels, previous: previous, first: first,
            second: second, price: instrument.last_price, atr: atr)
          choices << [setup, [previous, first, second]] if setup
        end
      end
      # Prefer the tightest valid invalidation when D/W zones overlap.
      setup, evidence = choices.min_by { |candidate, bars| [(candidate['stop'].to_d - instrument.last_price).abs, -bars.last.time.to_i] }
      register(instrument, setup, evidence, days, now: now) if setup
    end
    state['last_minute_at'] = minutes.last.time.iso8601
    instrument.update!(intraday_breakout_state: state)
  end

  def self.register(instrument, setup, evidence, days, now:)
    up = setup['direction'] == 'up'
    instrument.signals.find_or_create_by!(event_key: "intraday-level-breakout:v1:#{instrument.id}:#{setup['level_id']}:#{setup['break_at']}") do |signal|
      signal.assign_attributes(kind: KIND, experiment: EXPERIMENT, research_only: true,
        reversal_status: 'confirmed', confirmed_at: now, occurred_at: now,
        title: up ? 'Пробой сопротивления без ретеста · лонг' : 'Пробой поддержки без ретеста · шорт',
        details: { 'direction' => setup.fetch('direction'), 'setup' => setup, 'stop' => setup.fetch('stop'),
          'target' => setup.fetch('target'), 'room_risk' => setup.fetch('room_risk'),
          'decision_price' => instrument.last_price.to_s, 'touch_context' => TechnicalContext.trend(days, 'day'),
          'status_reason' => "Две завершённые минуты #{up ? 'выше сильного сопротивления' : 'ниже сильной поддержки'} с запасом 0,1 дневного ATR; ретест не требуется",
          'early_evidence' => evidence.map { |bar| { 'time' => bar.time.iso8601, 'close' => bar.close.to_s } },
          'rules' => { 'hold_minutes' => 2, 'buffer_atr' => LevelBreakoutSetup::BUFFER_ATR.to_f,
            'max_extension_atr' => LevelBreakoutSetup::MAX_EXTENSION_ATR.to_f,
            'min_room_risk' => LevelBreakoutSetup::MIN_ROOM_RISK.to_f,
            'target_policy' => 'nearest_confirmed_opposing_zone', 'cooldown_hours' => 6 } })
    end
  end
end
