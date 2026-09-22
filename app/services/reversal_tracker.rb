class ReversalTracker
  CONFIRMATION_WINDOW = 10.minutes
  COOLDOWN = 30.minutes
  LABELS = { 'possible' => 'Возможный', 'confirmed' => 'Подтверждён', 'cancelled' => 'Отменён', 'expired' => 'Не подтверждён' }.freeze

  def self.process(instrument, bar)
    return unless instrument.enabled? && instrument.reversal_enabled? && !instrument.expired?
    return unless bar.complete && bar.time > 5.minutes.ago

    instrument.with_lock do
      return if instrument.last_reversal_minute_at && bar.time <= instrument.last_reversal_minute_at
      instrument.update!(last_reversal_minute_at: bar.time)
      pending = instrument.signals.where(kind: 'reversal', reversal_status: 'possible').to_a
      pending.each { |signal| advance(signal, bar) }
      return if pending.any?

      bars = instrument.market_minutes.where(session: bar.session)
        .where(time: bar.time.in_time_zone.beginning_of_day..bar.time)
        .order(time: :desc).limit(Detectors::Reversal::WINDOWS.max + Detectors::Reversal::BASELINE + Detectors::Reversal::REBOUND).to_a.reverse
      details = Detectors::Reversal.evaluate(bars: bars)
      return unless details
      recent = instrument.signals.where(kind: 'reversal').where('occurred_at > ?', bar.time + 60 - COOLDOWN)
      return if recent.where("details ->> 'direction' = ?", details[:direction]).exists?

      instrument.signals.create!(kind: 'reversal', reversal_status: 'possible',
        event_key: "reversal:#{instrument.id}:#{bar.time.to_i}", occurred_at: bar.time + 60,
        title: details[:direction] == 'up' ? 'Откуп после снижения' : 'Продажи после роста', details: details)
    end
  end

  def self.advance(signal, bar)
    details = signal.details.dup
    previous_time = Time.iso8601(details.fetch('last_checked_at'))
    return if bar.time <= previous_time
    if bar.time + 60 > signal.occurred_at + CONFIRMATION_WINDOW
      return finish(signal, 'expired', 'Нет подтверждения за 10 минут', bar.time + 60)
    end
    unless bar.session == details['session'] && bar.time - previous_time == 60 &&
        bar.time.in_time_zone.to_date == previous_time.in_time_zone.to_date && Detectors::Reversal.valid_bar?(bar)
      return finish(signal, 'expired', 'Прерван непрерывный поток цен', bar.time + 60)
    end

    up = details['direction'] == 'up'
    sign = up ? 1 : -1
    volatility = details.fetch('volatility').to_d
    extreme = details.fetch('extreme').to_d
    if up ? bar.low_price < extreme - volatility * 0.1 : bar.high_price > extreme + volatility * 0.1
      return finish(signal, 'cancelled', 'Цена обновила экстремум исходного движения', bar.time + 60)
    end

    continued = sign * (bar.close_price - details.fetch('entry_price').to_d) >= volatility * 0.5
    details['confirmation_closes'] = continued ? details.fetch('confirmation_closes', 0) + 1 : 0
    details['last_checked_at'] = bar.time.iso8601
    signal.update!(details: details)
    if details['confirmation_closes'] >= 2
      finish(signal, 'confirmed', 'Два закрытия подряд за ценой сигнала на 0,5 обычного минутного диапазона', bar.time + 60)
    elsif bar.time + 60 >= signal.occurred_at + CONFIRMATION_WINDOW
      finish(signal, 'expired', 'Нет подтверждения за 10 минут', bar.time + 60)
    end
  end

  def self.finish(signal, status, reason, time)
    signal.update!(reversal_status: status, last_occurred_at: time,
      details: signal.details.merge('status_reason' => reason, 'status_at' => time.iso8601))
  end
end
