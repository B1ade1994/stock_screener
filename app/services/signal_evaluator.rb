class SignalEvaluator
  def self.volume(instrument, bar)
    return unless instrument.enabled? && instrument.volume_enabled? && bar.time > 5.minutes.ago
    history = instrument.market_minutes.where(session: bar.session).where('time < ?', bar.time).order(time: :desc).limit(20).to_a.reverse
    ready = history.size == 20 && history.all?(&:complete) && (history + [bar]).each_cons(2).all? { |a, b| b.time - a.time == 60 }
    # Restore only the total-volume baseline. Never reconstruct historical BUY/SELL.
    history = instrument.reversal_minutes.where('time < ?', bar.time).order(time: :desc).limit(20).to_a.reverse unless ready
    details = Detectors::Volume.evaluate(current: bar, history: history, multiplier: instrument.volume_multiplier, minimum: instrument.minimum_volume, canonical: !ready)
    return unless details
    time_baseline = VolumeTimeBaseline.evaluate(instrument: instrument, bar: bar)
    quality = VolumeQuality.evaluate(instrument: instrument, bar: bar, history: history, time_baseline: time_baseline).merge(baseline_source: details[:baseline_source])
    VolumeEpisode.record(instrument: instrument, bar: bar, details: details.merge(open_price: bar.open_price&.to_s,
      close_price: bar.close_price&.to_s, high_price: bar.high_price&.to_s, low_price: bar.low_price&.to_s, quality: quality))
  end
  def self.crossings(instrument, price, time)
    instrument.with_lock do
      return unless instrument.enabled? && instrument.breakout_enabled? && time > 30.seconds.ago
      return unless instrument.last_trade_at && time > instrument.last_trade_at && time - instrument.last_trade_at < 120
      levels = instrument.price_levels.alertable.to_a
      strength = LevelStrength.new(levels)
      crossed = levels.select do |level|
        strength.call(level).grade == 3 && (!level.last_alert_at || level.last_alert_at <= 6.hours.ago) && level.crossed?(instrument.last_price, price)
      end
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
          snapshots = group.map { |level| { id: level.id, timeframe: level.timeframe, lower: level.lower_bound.to_s, upper: level.upper_bound.to_s, price: level.price.to_s, buffer: level.breakout_buffer.to_s } }
          MarketSignal.create!(instrument: instrument, kind: "crossing", event_key: "crossing:#{first.id}:#{time.to_f}", occurred_at: time,
            title: group.size > 1 ? "Пересечение группы сильных уровней (#{group.size})" : "Пересечение #{first.timeframe == 'week' ? 'недельного' : 'дневного'} уровня",
            details: { level_id: first.id, levels: snapshots, strength_grade: 3,
              lower: group.map(&:lower_bound).min.to_s, upper: group.map(&:upper_bound).max.to_s,
              buffer: first.breakout_buffer.to_s, level: first.price.to_s, price: price.to_s, side: first.side,
              timeframe: first.timeframe, confirmation: "Ожидает закрытия свечи" })
          group.each { |level| level.update!(last_alert_at: time) }
        end
      end
    end
  end
end
