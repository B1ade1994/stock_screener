class DailyRetestResearch
  KIND = 'daily_retest'
  EXPERIMENT = 'daily_retest_v1'

  def self.eligible?(instrument)
    instrument.future? || instrument.metal?
  end

  def self.call(instrument, now: Time.current)
    return unless eligible?(instrument)
    instrument.with_lock do
      days = instrument.candles.where(timeframe: 'day', data_source: 't_invest')
        .where('time < ?', now.in_time_zone.beginning_of_day).order(:time).to_a
      return if days.empty?
      instrument.signals.where(kind: KIND).where("details ->> 'measurement_complete' = 'false'").each do |signal|
        DailyRetestOutcome.refresh(signal, days)
      end
      state = instrument.daily_retest_state.deep_dup
      enabled = instrument.enabled? && !instrument.expired? && instrument.breakout_enabled?
      if state.empty? || !enabled || state['enabled'] == false
        return if !enabled && state['enabled'] == false && state['cursor'] == days.last.time.iso8601
        instrument.update!(daily_retest_state: { 'started_at' => now.iso8601,
          'cursor' => days.last.time.iso8601, 'enabled' => enabled, 'pending' => [], 'cooldown' => 0 })
        return
      end
      cursor = Time.iso8601(state.fetch('cursor'))
      start_day = Time.iso8601(state.fetch('started_at')).in_time_zone.beginning_of_day
      return if days.last.time <= cursor
      daily = DailyRetestLevels.new(instrument.id, 'day')
      weekly = DailyRetestLevels.new(instrument.id, 'week')
      weeks = instrument.candles.where(timeframe: 'week', data_source: 't_invest').order(:time).select { |bar| valid_bar?(bar) }
      wi = 0
      atrs = MarketIndicators.atr(days)
      days.each_with_index do |bar, index|
        while wi < weeks.size && weeks[wi].time + 7.days <= bar.time
          weekly.push(weeks[wi]); wi += 1
        end
        if bar.time > cursor
          previous = index.positive? ? days[index - 1] : nil
          if bar.time < start_day
            state['pending'] = []
          elsif !valid_bar?(bar) || !previous || !valid_bar?(previous) || bar.time - previous.time > 4.days
            state['pending'] = []
            state['last_skip'] = 'Неполные свечи или разрыв истории больше четырёх суток'
          else
            process(instrument, state, bar, previous: previous, atr: atrs[index - 1],
              strong: daily.strong + weekly.strong, latest: bar == days.last, now: now)
          end
          state['cursor'] = bar.time.iso8601
        end
        daily.push(bar) if valid_bar?(bar)
      end
      instrument.update!(daily_retest_state: state)
    end
  end

  def self.process(instrument, state, bar, previous:, atr:, strong:, latest:, now:)
    blocked = state.fetch('cooldown', 0).positive?
    state['cooldown'] = [state.fetch('cooldown', 0) - 1, 0].max
    advanced = state.fetch('pending', []).map { |setup| DailyRetestSetup.advance(setup, bar) }
    confirmed = advanced.select { |setup| setup['status'] == 'confirmed' }
    state['pending'] = advanced.select { |setup| setup['status'] == 'possible' }
    advanced.reject { |setup| setup['status'] == 'possible' }.each do |setup|
      key = "#{setup['status']}_count"
      state[key] = state.fetch(key, 0) + 1
    end
    if confirmed.any? && confirmed.map { |setup| setup['direction'] }.uniq.size == 1 && !blocked
      # Recovered old days cannot manufacture prospective entries.
      if latest && bar.time >= now - 4.days
        up = confirmed.first['direction'] == 'up'
        stop = up ? confirmed.map { |s| s['stop'].to_d }.min : confirmed.map { |s| s['stop'].to_d }.max
        instrument.signals.find_or_create_by!(event_key: "daily-retest:v1:#{instrument.id}:#{bar.time.to_i}") do |signal|
          signal.assign_attributes(kind: KIND, experiment: EXPERIMENT, research_only: true,
            reversal_status: 'confirmed', confirmed_at: now, occurred_at: now,
            title: up ? 'Дневной ретест · лонг' : 'Дневной ретест · шорт',
            details: { 'direction' => up ? 'up' : 'down', 'zones' => confirmed, 'stop' => stop.to_s,
              'decision_price' => bar.close.to_s, 'retest_at' => bar.time.iso8601,
              'entry_policy' => 'first_daily_open_after_registration', 'measurement_complete' => false,
              'outcomes' => {}, 'rules' => { 'buffer_atr' => 0.1, 'retest_bars' => 5, 'target_r' => 2, 'primary_horizon' => 5 } })
        end
      else
        state['late_count'] = state.fetch('late_count', 0) + 1
      end
      state['cooldown'] = 10
    end
    strong.each do |level|
      setup = DailyRetestSetup.start(level, previous: previous, bar: bar, atr: atr)
      state['pending'] << setup if setup
    end
  end

  def self.valid_bar?(bar)
    values = [bar.open, bar.high, bar.low, bar.close]
    values.all? { |price| price && price.finite? && price.positive? } &&
      bar.high >= [bar.open, bar.close, bar.low].max && bar.low <= [bar.open, bar.close].min
  end
end
