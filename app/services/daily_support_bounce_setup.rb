# A distinct hypothesis: defend the lower edge, not break the upper edge.
# All zone geometry, ATR and EMA evidence are frozen before confirmation.
class DailySupportBounceSetup
  TOUCH_ATR = BigDecimal('0.25')
  BREAK_ATR = BigDecimal('0.5')
  BUFFER_ATR = BigDecimal('0.1')
  EMA_NEAR_ATR = BigDecimal('0.5')
  CONFIRMATION_BARS = 3

  def self.start(level, previous:, bar:, atr:, weekly:)
    return unless level.side == 'support' && previous && atr&.finite? && atr.positive?
    atr = atr.to_d
    lower = level.lower_price.to_d
    buffer = atr * BUFFER_ATR
    return unless previous.close > lower + buffer
    return unless bar.low <= lower + atr * TOUCH_ATR && bar.low >= lower - atr * BREAK_ATR && bar.high >= lower
    return unless bar.close >= lower - atr * BREAK_ATR

    ema = weekly.dig('ema', 40)
    { 'status' => 'possible', 'bars' => 0, 'direction' => 'up',
      'lower' => lower.to_s, 'upper' => level.upper_price.to_s, 'frame' => level.timeframe,
      'score' => level.assessment['score'], 'level_as_of' => level.assessment['as_of'],
      'touches' => level.touches, 'atr' => atr.to_s, 'buffer' => buffer.to_s,
      'touch_at' => bar.time.iso8601, 'touch_close' => bar.close.to_s, 'extreme' => bar.low.to_s,
      'stop' => (bar.low - buffer).to_s, 'weekly_ema40' => ema,
      'weekly_as_of' => weekly['as_of'],
      'near_weekly_ema40' => !!(ema && (bar.low - ema.to_d).abs <= atr * EMA_NEAR_ATR) }
  end

  def self.advance(setup, bar)
    state = setup.deep_dup
    return state unless state['status'] == 'possible'
    state['bars'] += 1
    lower, extreme, buffer, atr = %w[lower extreme buffer atr].map { |key| state.fetch(key).to_d }
    if bar.low <= extreme - buffer || bar.close < lower - atr * BREAK_ATR
      state.merge!('status' => 'cancelled', 'reason' => 'Новый минимум за границей отмены или глубокое закрытие под поддержкой')
    elsif state['bars'] > CONFIRMATION_BARS
      state.merge!('status' => 'expired', 'reason' => 'Нет дневного подтверждения за три свечи')
    elsif bar.close > [lower, state.fetch('touch_close').to_d].max + buffer && bar.close > bar.open && bar.low > extreme
      state.merge!('status' => 'confirmed', 'confirmation_at' => bar.time.iso8601,
        'decision_price' => bar.close.to_s, 'reason' => 'Растущее дневное закрытие выше границы поддержки и закрытия касания; минимум выше')
      state['ema40_reclaimed'] = !!(state['near_weekly_ema40'] && bar.close > state['weekly_ema40'].to_d + buffer)
    elsif state['bars'] >= CONFIRMATION_BARS
      state.merge!('status' => 'expired', 'reason' => 'Нет дневного подтверждения за три свечи')
    end
    state
  end
end
