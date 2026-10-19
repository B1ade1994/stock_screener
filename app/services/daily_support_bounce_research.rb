class DailySupportBounceResearch
  KIND = 'daily_support_bounce'
  EXPERIMENT = 'daily_support_bounce_v1'
  COOLDOWN_BARS = 10

  def self.call(instrument, now: Time.current)
    return unless DailyRetestResearch.eligible?(instrument)
    instrument.with_lock do
      days = instrument.candles.where(timeframe: 'day', data_source: 't_invest')
        .where('time < ? AND time <= ?', now.in_time_zone.beginning_of_day, now - 1.day).order(:time).to_a
      return if days.empty?
      instrument.signals.where(kind: KIND).where.not(confirmed_at: nil)
        .where("details ->> 'measurement_complete' = 'false'").each { |signal| DailyRetestOutcome.refresh(signal, days) }
      state = instrument.daily_support_bounce_state.deep_dup
      enabled = instrument.enabled? && !instrument.expired? && instrument.breakout_enabled?
      if state.empty? || !enabled || state['enabled'] == false
        cancel_pending(instrument, 'Наблюдение выключено или начато заново', now: now)
        instrument.update!(daily_support_bounce_state: { 'started_at' => now.iso8601,
          'cursor' => days.last.time.iso8601, 'enabled' => enabled, 'cooldown' => 0 })
        return
      end
      cursor = Time.iso8601(state.fetch('cursor'))
      return if days.last.time <= cursor
      start_day = Time.iso8601(state.fetch('started_at')).in_time_zone.beginning_of_day
      daily = DailyRetestLevels.new(instrument.id, 'day')
      weekly = DailyRetestLevels.new(instrument.id, 'week')
      weeks = instrument.candles.where(timeframe: 'week', data_source: 't_invest').order(:time).to_a
      closed_weeks = []
      wi = 0
      atrs = MarketIndicators.atr(days)
      valid_prefix = true
      valid_weeks = true
      days.each_with_index do |bar, index|
        while wi < weeks.size && weeks[wi].time + 7.days <= bar.time
          valid_weeks &&= DailyRetestResearch.valid_bar?(weeks[wi])
          if valid_weeks
            weekly.push(weeks[wi])
            closed_weeks << weeks[wi]
          end
          wi += 1
        end
        valid_prefix &&= DailyRetestResearch.valid_bar?(bar)
        if bar.time > cursor
          previous = index.positive? ? days[index - 1] : nil
          if bar.time < start_day || !valid_prefix || !previous || bar.time - previous.time > 4.days
            cancel_pending(instrument, 'Неполная история, разрыв больше четырёх суток или свеча до запуска', now: now)
          else
            process(instrument, state, bar, previous: previous, atr: atrs[index - 1],
              strong: daily.strong + (valid_weeks ? weekly.strong : []),
              weekly: valid_weeks ? MarketIndicators.context(closed_weeks, 'week') : {},
              daily: TechnicalContext.trend(days.first(index + 1), 'day'),
              latest: bar == days.last, now: now)
          end
          state['cursor'] = bar.time.iso8601
        end
        daily.push(bar) if valid_prefix
      end
      instrument.update!(daily_support_bounce_state: state)
    end
  end

  def self.process(instrument, state, bar, previous:, atr:, strong:, weekly:, daily:, latest:, now:)
    blocked = state.fetch('cooldown', 0).positive?
    state['cooldown'] = [state.fetch('cooldown', 0) - 1, 0].max
    pending = instrument.signals.where(kind: KIND, reversal_status: 'possible').to_a
    pending.each do |signal|
      setup = DailySupportBounceSetup.advance(signal.details.fetch('setup'), bar)
      if setup['status'] == 'confirmed' && (!latest || bar.time < now - 4.days)
        setup.merge!('status' => 'expired', 'reason' => 'Подтверждение поступило с опозданием; исторический вход не создаётся')
      end
      details = signal.details.merge('setup' => setup, 'status_reason' => setup['reason'], 'status_at' => now.iso8601)
      attrs = { reversal_status: setup['status'], details: details }
      if setup['status'] == 'confirmed'
        details.merge!('decision_price' => bar.close.to_s, 'confirmation_at' => bar.time.iso8601,
          'confirmation_context' => daily, 'measurement_complete' => false, 'outcomes' => {})
        attrs[:confirmed_at] = now
        attrs[:title] = 'Отскок от поддержки · лонг'
        state['cooldown'] = COOLDOWN_BARS
      end
      signal.update!(attrs)
    end
    return if pending.any? || blocked || !latest || bar.time < now - 4.days

    setups = strong.filter_map { |zone| DailySupportBounceSetup.start(zone, previous: previous, bar: bar, atr: atr, weekly: weekly) }
    setup = setups.min_by { |s| [(bar.low - s['lower'].to_d).abs, s['frame'] == 'week' ? 0 : 1, -s['score'].to_f] }
    return unless setup
    instrument.signals.find_or_create_by!(event_key: "daily-support-bounce:v1:#{instrument.id}:#{bar.time.to_i}") do |signal|
      signal.assign_attributes(kind: KIND, experiment: EXPERIMENT, research_only: true,
        reversal_status: 'possible', occurred_at: now, title: 'Отскок от поддержки · кандидат в лонг',
        details: { 'direction' => 'up', 'setup' => setup, 'decision_price' => bar.close.to_s,
          'stop' => setup['stop'], 'touch_context' => daily,
          'status_reason' => 'Касание нижней границы сильной поддержки; ждём дневной возврат с более высоким минимумом',
          'entry_policy' => 'first_daily_open_after_confirmation_registration',
          'rules' => { 'touch_atr' => DailySupportBounceSetup::TOUCH_ATR.to_f,
            'break_atr' => DailySupportBounceSetup::BREAK_ATR.to_f, 'buffer_atr' => DailySupportBounceSetup::BUFFER_ATR.to_f,
            'confirmation_bars' => DailySupportBounceSetup::CONFIRMATION_BARS,
            'ema_near_atr' => DailySupportBounceSetup::EMA_NEAR_ATR.to_f, 'target_r' => 2, 'primary_horizon' => 5 } })
    end
  end

  def self.cancel_pending(instrument, reason, now:)
    instrument.signals.where(kind: KIND, reversal_status: 'possible').each do |signal|
      signal.update!(reversal_status: 'cancelled', details: signal.details.merge('status_reason' => reason,
        'status_at' => now.iso8601, 'setup' => signal.details.fetch('setup').merge('status' => 'cancelled', 'reason' => reason)))
    end
  end
end
