class SignalEvaluator
  def self.volume(instrument, bar)
    return unless instrument.enabled? && instrument.volume_enabled? && bar.time > 5.minutes.ago
    history = instrument.market_minutes.where(session: bar.session).where('time < ?', bar.time).order(time: :desc).limit(20).to_a.reverse
    details = Detectors::Volume.evaluate(current: bar, history: history, multiplier: instrument.volume_multiplier, minimum: instrument.minimum_volume)
    return unless details
    key = "volume:#{instrument.id}:#{bar.time.to_i}"
    MarketSignal.find_or_create_by!(event_key: key) do |signal|
      signal.assign_attributes(instrument: instrument, kind: "volume", occurred_at: bar.time + 60, title: "Объём за минуту ×#{details[:ratio]}", details: details.merge(baseline_description: "Медиана предыдущих 20 полных минут без разрывов"))
    end
  end
  def self.crossings(instrument, price, time)
    return unless instrument.enabled? && instrument.breakout_enabled? && time > 30.seconds.ago
    return unless instrument.last_trade_at && time > instrument.last_trade_at && time - instrument.last_trade_at < 120
    instrument.price_levels.alertable.each do |level|
      next if level.last_alert_at && level.last_alert_at > 6.hours.ago
      next unless level.crossed?(instrument.last_price, price)
      MarketSignal.create!(instrument: instrument, kind: "crossing", event_key: "crossing:#{level.id}:#{time.to_f}", occurred_at: time, title: "Пересечение #{level.timeframe == 'week' ? 'недельного' : 'дневного'} уровня", details: { lower: level.lower_bound.to_s, upper: level.upper_bound.to_s, buffer: level.breakout_buffer.to_s, level: level.price.to_s, price: price.to_s, side: level.side, timeframe: level.timeframe, confirmation: "Ожидает закрытия свечи" })
      level.update!(last_alert_at: time)
    end
  end
end
