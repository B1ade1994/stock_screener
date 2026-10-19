# Silent prospective research. A state is a rule outcome, never a calibrated
# probability or an order. Existing detectors/notification cursors stay intact.
class DirectionalHints
  KIND = 'directional_hint'
  EXPERIMENT = 'directional_v1'
  CONFIRMATION_WINDOW = 10.minutes
  MONITOR_WINDOW = 60.minutes
  LABELS = { 'forming' => 'Формируется сегодня', 'possible' => 'Ожидает подтверждения', 'confirmed' => 'Подтверждён по правилам',
    'cancelled' => 'Отменён', 'expired' => 'Не подтверждён', 'missed' => 'Движение подтверждено, вход пропущен' }.freeze

  def self.call(instrument, now: Time.current, collect: false)
    instrument.with_lock do
      active = instrument.signals.where(kind: KIND).where("details ->> 'monitoring' = 'true'").to_a
      through = (now - 95.seconds).beginning_of_minute
      active.each do |hint|
        service = hint.experiment == DirectionalHintResearch::EXPERIMENT ? DirectionalHintResearch : self
        service.advance_history(hint, through, now: now)
      end
      # Research outcomes never occupy or release the control's candidate slot.
      active = active.select { |hint| hint.experiment == EXPERIMENT }
      instrument.signals.where(kind: KIND).where("details -> 'lifecycle' ->> 'status' = 'pending'").each do |hint|
        HintLifecycle.refresh(hint, now: now)
      end
      return unless collect # Retired: only finish existing observations.
      return unless instrument.enabled? && !instrument.expired? && instrument.reversal_enabled?
      bars = instrument.reversal_minutes.where(time: now.in_time_zone.beginning_of_day..through)
        .order(time: :desc).limit(Detectors::ShockReversal::LOOKBACK).to_a.reverse
      bar = bars.last
      return unless bar && bar.time > now - 5.minutes && Detectors::Reversal.valid_bar?(bar)

      if instrument.reversal_enabled?
        shock = Detectors::ShockReversal.evaluate(bars: bars)
        if shock
          key = "hint:shock:#{instrument.id}:#{shock[:direction]}:#{shock[:extreme_at]}"
          unless instrument.signals.exists?(event_key: key)
            active.select { |hint| hint.details['monitoring'] && hint.details['direction'] != shock[:direction] }.each do |hint|
              finish(hint, 'cancelled', 'Противоположный резкий отскок: конфликт сценариев, не касание границы цены', now: now, bar: bar)
            end
            unless active.any? { |hint| hint.details['monitoring'] }
              return create(instrument, bar, shock, key: key, basis: 'Резкий импульс и два закрытия отскока', now: now)
            end
          end
        end
      end
      return if active.any? { |hint| hint.details['monitoring'] }
      sources = instrument.signals.where(kind: %w[reversal crossing], created_at: (now - 5.minutes)..now)
        .where(occurred_at: (now - 5.minutes)..(bar.time + 60)).order(:created_at, :id)
      sources.each do |source|
        next if instrument.signals.exists?(event_key: "hint:source:#{source.id}")
        d = source.details
        if source.kind == 'reversal'
          next unless instrument.reversal_enabled? && %w[possible confirmed].include?(source.reversal_status)
          next unless d.values_at('extreme', 'volatility', 'rebound_boundary', 'direction').all?(&:present?)
          config = d.symbolize_keys.slice(:direction, :extreme, :volatility, :rebound_boundary, :impulse_minutes, :relative_volume)
          basis = source.experiment.present? ? 'Отскок после длительного движения' : 'Отскок основного детектора'
        else
          next unless instrument.breakout_enabled? && d['strength_grade'].to_i == 3
          next unless %w[support resistance].include?(d['side']) && d.values_at('lower', 'upper', 'buffer').all?(&:present?)
          up = d['side'] == 'resistance'
          boundary = d.fetch(up ? 'upper' : 'lower').to_d
          buffer = d.fetch('buffer').to_d
          next unless buffer.positive? && (up ? bar.close_price >= boundary + buffer : bar.close_price <= boundary - buffer)
          config = { direction: up ? 'up' : 'down', extreme: boundary.to_s, volatility: buffer.to_s,
            rebound_boundary: (boundary + (up ? buffer : -buffer)).to_s, invalidation: boundary.to_s }
          basis = 'Минутное закрытие за сильным уровнем'
        end
        config[:source_experiment] = source.experiment
        config[:source_signal_id] = source.id
        config[:scenario] = source.kind
        hint = create(instrument, bar, config, key: "hint:source:#{source.id}", basis: basis, now: now)
        return hint if hint
      end
      nil
    end
  end

  def self.create(instrument, bar, config, key:, basis:, now:)
    up = config.fetch(:direction) == 'up'
    sign = up ? 1 : -1
    atr = config.fetch(:volatility).to_d
    return unless atr.positive?
    invalidation = config[:invalidation]&.to_d || config.fetch(:extreme).to_d - sign * atr * BigDecimal('0.1')
    return if up ? bar.low_price <= invalidation : bar.high_price >= invalidation
    # Freeze all decision prices; later candles only advance the state.
    boundary = config.fetch(:rebound_boundary).to_d + sign * atr * BigDecimal('0.1')
    instrument.signals.transaction do
      hint = instrument.signals.create!(kind: KIND, research_only: true, experiment: EXPERIMENT,
        reversal_status: 'possible', event_key: key, occurred_at: bar.time + 60,
        title: up ? 'Кандидат в лонг' : 'Кандидат в шорт',
        details: config.merge(version: 1, basis: basis, decision_at: now.iso8601, decision_price: bar.close_price.to_s,
          confirmation_price: boundary.to_s, invalidation: invalidation.to_s, horizons: [15, 60],
          last_checked_at: bar.time.iso8601, confirmation_closes: 0, monitoring: true,
          confirmation_deadline: (now + CONFIRMATION_WINDOW).iso8601,
          status_reason: 'Ждём два последовательных минутных закрытия за границей подтверждения'))
      DirectionalHintResearch.create_from(hint, bar, now: now)
      hint
    end
  end

  def self.advance_history(hint, through, now:)
    previous = Time.iso8601(hint.details.fetch('last_checked_at'))
    hint.instrument.reversal_minutes.where(time: (previous + 60)..through).order(:time).each do |bar|
      break unless bar.time == previous + 60 && Detectors::Reversal.valid_bar?(bar)
      break if bar.time.in_time_zone.to_date != previous.in_time_zone.to_date
      advance(hint, bar, now: now)
      break unless hint.details['monitoring']
      previous = bar.time
    end
    expire(hint, now: now)
  end

  def self.advance(hint, bar, now: Time.current)
    d = hint.details.deep_dup
    return unless d['monitoring'] && bar.time > Time.iso8601(d.fetch('last_checked_at'))
    deadline = hint.confirmed_at ? hint.confirmed_at + MONITOR_WINDOW : Time.iso8601(d.fetch('confirmation_deadline'))
    return if bar.time + 60 > deadline
    up = d.fetch('direction') == 'up'
    invalidation = d.fetch('invalidation').to_d
    if up ? bar.low_price <= invalidation : bar.high_price >= invalidation
      return finish(hint, 'cancelled', 'Цена достигла границы отмены сценария', now: now, bar: bar)
    end
    beyond = (up ? 1 : -1) * (bar.close_price - d.fetch('confirmation_price').to_d) >= 0
    d['last_checked_at'] = bar.time.iso8601
    d['confirmation_closes'] = beyond ? d.fetch('confirmation_closes') + 1 : 0
    if hint.reversal_status == 'possible' && d['confirmation_closes'] >= 2
      # A recovered old candle cannot manufacture a historical entry point.
      return finish(hint, 'expired', 'Подтверждение поступило после срока ожидания', now: now, bar: bar) if now > deadline + 2.minutes
      d['confirmed_bar_at'] = (bar.time + 60).iso8601
      d['status_reason'] = 'Два закрытия за границей; сценарий остаётся экспериментальным'
      d['status_at'] = now.iso8601
      HintLifecycle.start(d, now: now)
      hint.update!(reversal_status: 'confirmed', confirmed_at: now, details: d)
    else
      hint.update!(details: d)
    end
  end

  def self.finish(hint, status, reason, now:, bar: nil)
    d = hint.details.merge('monitoring' => false,
      'status_reason' => reason, 'status_at' => now.iso8601, 'status_bar_at' => bar && (bar.time + 60).iso8601)
    HintLifecycle.close(d, now: now, reason: reason) if hint.confirmed_at
    hint.update!(reversal_status: status, details: d)
    # A control conflict also cancels its paired experiment, without coupling
    # ordinary price invalidations (the retest experiment has a different stop).
    if hint.experiment == EXPERIMENT && reason.include?('конфликт сценариев')
      paired = hint.instrument.signals.find_by(event_key: "hint:v2:#{hint.id}")
      finish(paired, status, reason, now: now, bar: bar) if paired&.details&.fetch('monitoring', false)
    end
  end

  def self.expire(hint, now:)
    return unless hint.details['monitoring']
    deadline = hint.confirmed_at ? hint.confirmed_at + MONITOR_WINDOW : Time.iso8601(hint.details.fetch('confirmation_deadline'))
    return unless now > deadline + 2.minutes
    if hint.confirmed_at
      complete = Time.iso8601(hint.details.fetch('last_checked_at')) + 60 >= deadline.beginning_of_minute
      reason = complete ? 'Час наблюдения завершён; результат смотрите в замерах' : 'Час истёк, но контроль отмены неполный: есть пропуски минут'
      d = hint.details.merge('monitoring' => false, 'monitoring_complete' => complete, 'status_reason' => reason)
      HintLifecycle.close(d, now: now, reason: reason, complete: complete)
      hint.update!(details: d)
    else
      finish(hint, 'expired', 'Нет подтверждения за 10 минут или поступили неполные данные', now: now)
    end
  end
end
