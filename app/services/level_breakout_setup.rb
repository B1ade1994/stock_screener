# Daily/weekly structure supplies the zone, stop and destination. Only the
# trigger uses minutes; no retest or completed current daily candle is required.
class LevelBreakoutSetup
  BUFFER_ATR = BigDecimal('0.1')
  MAX_EXTENSION_ATR = BigDecimal('0.5')
  MIN_ROOM_RISK = BigDecimal('1.5')

  def self.start(level, levels:, previous:, first:, second:, price:, atr:)
    return unless atr&.finite? && atr.positive? && price&.finite? && price.positive?
    return unless [previous, first, second].all? { |bar| DailyRetestResearch.valid_bar?(bar) }
    return unless first.time == previous.time + 1.minute && second.time == first.time + 1.minute
    up = level.side == 'resistance'
    sign = up ? 1 : -1
    buffer = atr.to_d * BUFFER_ATR
    edge = up ? level.upper_bound : level.lower_bound
    boundary = edge + sign * buffer
    return unless sign * (previous.close - boundary) <= 0 &&
      [first.close, second.close, price].all? { |value| sign * (value - boundary) > 0 }
    return if [first.close, second.close, price].any? { |value| sign * (value - edge) > atr.to_d * MAX_EXTENSION_ATR }

    destinations = levels.select { |row| row.side == level.side && row.id != level.id }
    # Do not advertise room through an opposing zone that already contains price.
    return if destinations.any? { |row| price.between?(row.lower_bound, row.upper_bound) }
    destination = if up
      destinations.select { |row| row.lower_bound > price }.min_by(&:lower_bound)
    else
      destinations.select { |row| row.upper_bound < price }.max_by(&:upper_bound)
    end
    return unless destination

    stop = up ? level.lower_bound - buffer : level.upper_bound + buffer
    target = up ? destination.lower_bound : destination.upper_bound
    ratio = (target - price) * sign / ((price - stop) * sign)
    return if ratio < MIN_ROOM_RISK
    { 'direction' => up ? 'up' : 'down', 'level_id' => level.id, 'side' => level.side, 'frame' => level.timeframe,
      'lower' => level.lower_bound.to_s, 'upper' => level.upper_bound.to_s,
      'level_as_of' => level.assessment.fetch('as_of'), 'score' => level.assessment['score'],
      'touches' => level.touches, 'atr' => atr.to_s, 'buffer' => buffer.to_s,
      'break_at' => first.time.iso8601, 'stop' => stop.to_s, 'target' => target.to_s,
      'room_risk' => ratio.to_f, 'target_zone' => { 'level_id' => destination.id,
        'frame' => destination.timeframe, 'side' => destination.side, 'lower' => destination.lower_bound.to_s,
        'upper' => destination.upper_bound.to_s, 'level_as_of' => destination.assessment.fetch('as_of') } }
  end
end
