# A prospective early warning, measured separately from the closed-day strategy.
# Daily/weekly zones and ATR are frozen; minutes only establish touch and holding.
class IntradaySupportBounce
  KIND = 'intraday_support_bounce'
  EXPERIMENT = 'intraday_support_bounce_v1'
  Minute = Struct.new(:time, :open, :high, :low, :close, :volume, keyword_init: true)
  LOOKBACK = 15.minutes

  def self.call(instrument, now: Time.current, client: TInvest::Client.new)
    return unless DailyRetestResearch.eligible?(instrument)
    ready = instrument.with_lock do
      state = instrument.intraday_bounce_state
      enabled = instrument.enabled? && instrument.breakout_enabled? && !instrument.expired?
      if state.empty? || !enabled || state['enabled'] == false
        instrument.signals.where(kind: KIND, reversal_status: 'forming').each do |signal|
          finish(signal, 'cancelled', 'Наблюдение выключено или начато заново', now: now)
        end
        instrument.update!(intraday_bounce_state: { 'enabled' => enabled, 'started_at' => now.iso8601,
          'last_minute_at' => now.beginning_of_minute.iso8601 })
        reconcile(instrument, now: now)
        false
      else
        reconcile(instrument, now: now)
        true
      end
    end
    return unless ready

    # No network operations while holding the instrument's row lock.
    snapshot = CurrentDayCandle.call(instrument, now: now, client: client)
    through = (now - 95.seconds).beginning_of_minute
    from = [through - LOOKBACK, now.utc.beginning_of_day].max
    return if from > through
    minutes = client.minute_candles(instrument.uid, from: from, to: through + 1.minute)
      .map { |row| Minute.new(**row) }.select { |bar| bar.time.between?(from, through) }
      .uniq(&:time).sort_by(&:time)
    instrument.with_lock do
      return unless instrument.enabled? && instrument.breakout_enabled? && !instrument.expired?
      process(instrument, snapshot, minutes, now: now)
    end
  end

  def self.process(instrument, snapshot, minutes, now:)
    state = instrument.intraday_bounce_state.deep_dup
    return unless state['enabled'] && minutes.any?
    period = now.utc.beginning_of_day
    return if snapshot && Time.iso8601(snapshot.fetch('time')) != period
    return unless minutes.all? { |bar| DailyRetestResearch.valid_bar?(bar) }
    last_at = Time.iso8601(state.fetch('last_minute_at'))
    return if minutes.last.time <= last_at

    active = instrument.signals.where(kind: KIND, reversal_status: 'forming').first
    if active && Time.iso8601(active.details.dig('setup', 'touch_at')) == period
      d = active.details
      control_start = [last_at + 1.minute, Time.at((active.created_at.to_i / 60 + 1) * 60)].max
      recent = minutes.select { |bar| bar.time >= control_start }
      if (snapshot && snapshot.fetch('low').to_d <= d.fetch('stop').to_d) || recent.any? { |bar| bar.low <= d.fetch('stop').to_d }
        finish(active, 'cancelled', 'Цена прошла за зафиксированную границу отмены', now: now)
      elsif recent.any? { |bar| bar.close < d.dig('setup', 'lower').to_d - d.dig('setup', 'buffer').to_d }
        finish(active, 'cancelled', 'Минутное закрытие вернулось под поддержку с запасом 0,1 ATR', now: now)
      elsif minutes.last.time >= control_start && (recent.first&.time != control_start || recent.each_cons(2).any? { |a, b| b.time != a.time + 1.minute })
        finish(active, 'expired', 'Пропуск минут контроля; удержание после появления идеи не оценено', now: now)
      end
    elsif snapshot && !active
      previous = instrument.signals.where(kind: KIND, created_at: period...(period + 1.day)).order(created_at: :desc, id: :desc).first
      # A new setup must begin after the previous idea ended, including legacy
      # ideas whose event key identified the entire day.
      restart_after = if previous&.reversal_status.in?(%w[cancelled expired])
        Time.iso8601(previous.details.fetch('status_at'))
      end
      days = completed_days(instrument, now)
      if (!previous || restart_after) && days.size >= 15 && days.all? { |bar| DailyRetestResearch.valid_bar?(bar) } && period - days.last.time <= 4.days
        create_candidate(instrument, snapshot, minutes, days, last_at: last_at, now: now, restart_after: restart_after)
      end
    end
    state['last_minute_at'] = minutes.last.time.iso8601
    instrument.update!(intraday_bounce_state: state)
  end

  def self.create_candidate(instrument, snapshot, minutes, days, last_at:, now:, restart_after: nil)
    period = now.utc.beginning_of_day
    atr = MarketIndicators.atr(days).last
    return unless atr&.finite? && atr.positive?
    live = Candle.new(time: period, **%w[open high low close].to_h { |field| [field.to_sym, snapshot.fetch(field)] })
    return unless DailyRetestResearch.valid_bar?(live)
    weeks = instrument.candles.where(timeframe: 'week', data_source: 't_invest').where('time <= ?', period - 7.days).order(:time).to_a
    weekly = weeks.all? { |bar| DailyRetestResearch.valid_bar?(bar) } ? MarketIndicators.context(weeks, 'week') : {}
    levels = instrument.price_levels.active.where(source: 'automatic', status: 'confirmed').to_a
      .select { |level| completed_level?(level, period) }
    strength = LevelStrength.new(levels)
    choices = levels.filter_map do |level|
      next unless strength.call(level).grade == 3
      setup = DailySupportBounceSetup.start(level, previous: days.last, bar: live, atr: atr, weekly: weekly)
      next unless setup
      boundary = setup.fetch('lower').to_d + setup.fetch('buffer').to_d
      evidence = minutes.each_cons(3).find do |touch, first, second|
        touch.time > Time.iso8601(instrument.intraday_bounce_state.fetch('started_at')) && second.time > last_at &&
          (!restart_after || touch.time > restart_after) &&
          first.time == touch.time + 1.minute && second.time == first.time + 1.minute &&
          second.time >= now - 4.minutes && touch.low <= level.lower_bound + atr.to_d * DailySupportBounceSetup::TOUCH_ATR &&
          touch.low >= level.lower_bound - atr.to_d * DailySupportBounceSetup::BREAK_ATR && touch.high >= level.lower_bound &&
          first.close > boundary && second.close > boundary && first.low > touch.low && second.low > touch.low &&
          second.close >= first.close && snapshot.fetch('close').to_d > boundary
      end
      [setup, evidence] if evidence
    end
    setup, evidence = choices.min_by { |candidate, _| [(live.low - candidate['lower'].to_d).abs, -candidate['score'].to_f] }
    return unless setup
    setup['status'] = 'forming'
    instrument.signals.create!(kind: KIND, experiment: EXPERIMENT, research_only: true, reversal_status: 'forming',
      event_key: event_key(instrument, period, evidence.first.time), occurred_at: now, title: 'Ранний отскок от поддержки · кандидат в лонг',
      details: { 'direction' => 'up', 'setup' => setup, 'decision_price' => snapshot.fetch('close').to_s,
        'stop' => setup.fetch('stop'), 'touch_context' => TechnicalContext.trend(days, 'day'),
        'status_reason' => 'Сегодняшнее касание поддержки и два последовательных минутных закрытия выше границы с запасом 0,1 ATR',
        'early_evidence' => evidence.map { |bar| { 'time' => bar.time.iso8601, 'close' => bar.close.to_s, 'low' => bar.low.to_s } },
        'early_price' => snapshot.fetch('close').to_s, 'day_snapshot' => snapshot,
        'confirmation_boundary' => (setup.fetch('lower').to_d + setup.fetch('buffer').to_d).to_s,
        'entry_policy' => 'first_daily_open_after_confirmation_registration',
        'rules' => { 'hold_minutes' => 2, 'buffer_atr' => 0.1, 'target_r' => 2, 'primary_horizon' => 5 } })
  end

  def self.reconcile(instrument, now:)
    days = completed_days(instrument, now)
    instrument.signals.where(kind: KIND).where.not(confirmed_at: nil)
      .where("details ->> 'measurement_complete' = 'false'").each { |signal| DailyRetestOutcome.refresh(signal, days) }
    instrument.signals.where(kind: KIND, reversal_status: 'forming').each do |signal|
      period = Time.iso8601(signal.details.dig('setup', 'touch_at'))
      next if period + 1.day > now
      bar = days.find { |candle| candle.time == period }
      if !bar
        finish(signal, 'expired', 'Завершённая дневная свеча не поступила за сутки после окончания периода', now: now) if now >= period + 2.days
      elsif !DailyRetestResearch.valid_bar?(bar)
        finish(signal, 'expired', 'Некорректная дневная свеча; подтверждение не оценивается', now: now)
      elsif bar.low <= signal.details.fetch('stop').to_d
        finish(signal, 'cancelled', 'Дневной минимум прошёл за границу отмены', now: now)
      elsif bar != days.last || now >= period + 2.days
        finish(signal, 'expired', 'Дневное подтверждение поступило с опозданием', now: now)
      elsif bar.close > signal.details.fetch('confirmation_boundary').to_d && bar.close > bar.open
        d = signal.details.deep_dup
        d.merge!('confirmation_at' => bar.time.iso8601, 'decision_price' => bar.close.to_s,
          'confirmation_context' => TechnicalContext.trend(days, 'day'), 'measurement_complete' => false, 'outcomes' => {},
          'status_reason' => 'День закрылся ростом выше зафиксированной границы поддержки с запасом 0,1 ATR')
        d['setup']['status'] = 'confirmed'
        signal.update!(reversal_status: 'confirmed', confirmed_at: now, title: 'Ранний отскок от поддержки · лонг подтверждён', details: d)
      else
        finish(signal, 'expired', 'Дневное закрытие не подтвердило ранний отскок', now: now)
      end
    end
  end

  def self.completed_days(instrument, now)
    instrument.candles.where(timeframe: 'day', data_source: 't_invest').where('time <= ?', now - 1.day).order(:time).to_a
  end

  def self.completed_level?(level, period)
    as_of = level.assessment['as_of']
    as_of && Time.iso8601(as_of) + (level.timeframe == 'week' ? 7.days : 1.day) <= period
  rescue ArgumentError
    false
  end

  def self.event_key(instrument, period, touch_at) = "intraday-support-bounce:v1:#{instrument.id}:#{period.to_i}:#{touch_at.to_i}"

  def self.finish(signal, status, reason, now:)
    d = signal.details.deep_dup
    d.merge!('status_reason' => reason, 'status_at' => now.iso8601)
    d['setup']['status'] = status
    signal.update!(reversal_status: status, details: d)
  end
end
