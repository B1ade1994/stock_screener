# The frozen hypothesis used by the historical review: daily closes, 0.1 ATR,
# retest within five subsequent bars. All inputs must already be completed.
class DailyRetestSetup
  def self.advance(setup, bar)
    state = setup.deep_dup
    state['bars'] += 1
    up = state['direction'] == 'up'
    lower, upper, buffer = %w[lower upper buffer].map { |key| state.fetch(key).to_d }
    if state['bars'] > 5
      state['status'] = 'expired'
    elsif up ? bar.close <= upper : bar.close >= lower
      state['status'] = 'cancelled'
    elsif (up ? bar.low <= upper + buffer && bar.high >= lower && bar.close > upper + buffer : bar.high >= lower - buffer && bar.low <= upper && bar.close < lower - buffer)
      state['status'] = 'confirmed'
      state['stop'] = (up ? [lower, bar.low].min - buffer : [upper, bar.high].max + buffer).to_s
    elsif state['bars'] >= 5
      state['status'] = 'expired'
    end
    state
  end

  def self.start(level, previous:, bar:, atr:)
    return unless previous && atr&.positive?
    up = level.side == 'resistance'
    buffer = atr.to_d * BigDecimal('0.1')
    crossed = up ? previous.close <= level.upper_price && bar.close > level.upper_price + buffer : previous.close >= level.lower_price && bar.close < level.lower_price - buffer
    return unless crossed
    { 'direction' => up ? 'up' : 'down', 'lower' => level.lower_price.to_s,
      'upper' => level.upper_price.to_s, 'buffer' => buffer.to_s, 'atr' => atr.to_s,
      'break_at' => bar.time.iso8601, 'frame' => level.timeframe,
      'score' => level.assessment['score'], 'level_as_of' => level.assessment['as_of'],
      'touches' => level.touches, 'bars' => 0, 'status' => 'possible' }
  end
end
