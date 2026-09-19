# Run before rebuilding zones, under the same instrument lock as streaming updates.
class LevelLifecycle
  HOLD_BARS = 5

  def self.call(instrument:, timeframe:, candles:)
    enabled = instrument.enabled? && instrument.breakout_enabled?
    instrument.price_levels.active.where(timeframe: timeframe).find_each do |level|
      unless enabled
        # Disabling alerts cancels pending scenarios and advances the cursor, without a later replay.
        level.update!(evaluated_at: candles.last&.time, breakout: {}, status: level.status == "broken" ? "confirmed" : level.status)
        next
      end
      candles.each_with_index do |candle, index|
        next if index.zero? || candle.time <= level.created_at || (level.evaluated_at && candle.time <= level.evaluated_at)
        if level.status == "broken"
          advance(instrument, level, candle, context: MarketIndicators.context(candles.first(index + 1), timeframe))
        elsif level.status == "confirmed" && level.crossed?(candles[index - 1].close, candle.close)
          state = { "lower" => level.lower_bound.to_s, "upper" => level.upper_bound.to_s,
            "buffer" => level.breakout_buffer.to_s, "side" => level.side, "started_at" => candle.time.iso8601, "bars" => 0 }
          emit(instrument, level, candle, "confirmed", "Закрытие за зоной: ожидаем удержания или ретеста", state, context: MarketIndicators.context(candles.first(index + 1), timeframe))
          level.update!(status: "broken", breakout: state)
        end
        level.update!(evaluated_at: candle.time)
      end
    end
  end

  def self.advance(instrument, level, candle, context:)
    state = level.breakout.dup
    resistance = state.fetch("side") == "resistance"
    lower, upper, buffer = %w[lower upper buffer].map { |key| state.fetch(key).to_d }
    returned = resistance ? candle.close <= upper : candle.close >= lower
    retest = resistance ? candle.low <= upper + buffer && candle.close > upper + buffer : candle.high >= lower - buffer && candle.close < lower - buffer
    state["bars"] += 1
    if returned
      emit(instrument, level, candle, "failed_breakout", "Возврат в зону после пробоя", state, context: context)
      level.update!(status: "confirmed", breakout: {})
    elsif retest || state["bars"] >= HOLD_BARS
      # A close inside the buffer is not proof of holding outside it.
      beyond = resistance ? candle.close > upper + buffer : candle.close < lower - buffer
      if retest || beyond
        kind = retest ? "retest" : "held_breakout"
        emit(instrument, level, candle, kind, retest ? "Ретест с закрытием за зоной: смена роли" : "Пять свечей без возврата: смена роли", state, context: context)
        level.update!(status: "confirmed", breakout: {}, side: resistance ? "support" : "resistance",
          assessment: level.assessment.merge("origin_side" => level.assessment["origin_side"] || level.side, "role_changed_at" => candle.time.iso8601))
      else
        level.update!(breakout: state)
      end
    else
      level.update!(breakout: state)
    end
  end

  def self.emit(instrument, level, candle, kind, title, state, context:)
    MarketSignal.find_or_create_by!(event_key: "#{kind}:#{level.id}:#{state['started_at']}:#{candle.time.to_i}") do |signal|
      signal.assign_attributes(instrument: instrument, kind: kind, occurred_at: Time.current, title: title,
        details: { trend: context, level_id: level.id, level: level.price.to_s, lower: state["lower"], upper: state["upper"], buffer: state["buffer"],
          close: candle.close.to_s, side: state["side"], timeframe: level.timeframe, candle_time: candle.time.iso8601,
          breakout_started_at: state["started_at"], confirmation: "#{level.timeframe == 'week' ? '1W' : '1D'} · свеча #{candle.time.in_time_zone.strftime('%d.%m.%Y')}" })
    end
  end
end
