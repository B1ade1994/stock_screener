# In-memory reconstruction: the current database levels cannot be used to make
# a decision about an earlier candle. No levels or alerts are written here.
class DailyRetestLevels
  Zone = Struct.new(:id, :instrument_id, :timeframe, :side, :price, :lower_price,
    :upper_price, :atr, :status, :touches, :assessment, :active, :role_changed,
    :breakout, keyword_init: true) do
    def active? = active
    def source = 'automatic'
  end

  def initialize(instrument_id, timeframe)
    @instrument_id, @timeframe = instrument_id, timeframe
    @levels, @bars, @next_id = [], [], 0
  end

  def strong
    active = @levels.select(&:active?)
    strength = LevelStrength.new(active)
    active.select { |level| strength.call(level).grade == 3 }
  end

  def push(bar)
    previous = @bars.last
    @bars << bar
    @levels.select(&:active?).each { |level| advance(level, previous, bar) } if previous
    used = []
    Detectors::Levels.candidates(@bars, timeframe: @timeframe).each do |candidate|
      level = @levels.reject { |row| used.include?(row.id) }.select do |row|
        row.assessment['origin_side'] == candidate[:side] &&
          row.lower_price <= candidate[:upper_price] && row.upper_price >= candidate[:lower_price]
      end.min_by { |row| (row.price - candidate[:price]).abs }
      if level
        used << level.id
        next if level.status == 'broken'
        candidate.each { |key, value| level[key] = key == :assessment ? value.stringify_keys : value unless key == :side }
        level.status = 'confirmed' if level.role_changed
        level.active = true
      else
        @next_id += 1
        level = Zone.new(**candidate.merge(assessment: candidate[:assessment].stringify_keys),
          id: @next_id, instrument_id: @instrument_id, timeframe: @timeframe,
          active: true, role_changed: false, breakout: {})
        @levels << level
        used << level.id
      end
    end
    @levels.each do |level|
      next if used.include?(level.id) || !level.active? || level.status == 'broken'
      level.active, level.status = false, 'archived'
    end
  end

  private

  def advance(level, previous, bar)
    if level.status == 'broken'
      state = level.breakout
      up = state[:side] == 'resistance'
      returned = up ? bar.close <= state[:upper] : bar.close >= state[:lower]
      beyond = up ? bar.close > state[:upper] + state[:buffer] : bar.close < state[:lower] - state[:buffer]
      touched = up ? bar.low <= state[:upper] + state[:buffer] : bar.high >= state[:lower] - state[:buffer]
      state[:bars] += 1
      if returned
        level.status, level.breakout = 'confirmed', {}
      elsif (touched || state[:bars] >= 5) && beyond
        level.status, level.side = 'confirmed', up ? 'support' : 'resistance'
        level.role_changed, level.breakout = true, {}
      end
    elsif level.status == 'confirmed'
      buffer = [level.atr.to_f * 0.1, 1e-9].max
      boundary = level.side == 'resistance' ? level.upper_price + buffer : level.lower_price - buffer
      crossed = level.side == 'resistance' ? previous.close <= boundary && bar.close > boundary : previous.close >= boundary && bar.close < boundary
      if crossed
        level.status = 'broken'
        level.breakout = { side: level.side, lower: level.lower_price, upper: level.upper_price, buffer: buffer, bars: 0 }
      end
    end
  end
end
