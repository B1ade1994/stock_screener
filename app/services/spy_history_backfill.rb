# One instrument and one chart: extend only the pre-launch part with raw SPY OHLC.
# Imported volume belongs to SPY, never to the MOEX future.
class SpyHistoryBackfill
  def self.call(instrument:, payload:, as_of: Date.current)
    raise ArgumentError, "Only SP500F is supported" unless instrument.ticker == "SP500F"
    meta = payload.fetch("meta")
    raise ArgumentError, "Expected SPY in USD" unless meta["symbol"] == "SPY" && meta["currency"] == "USD"
    quotes = payload.fetch("indicators").fetch("quote").fetch(0)
    rows = payload.fetch("timestamp").each_with_index.map do |timestamp, index|
      date = Time.at(timestamp).in_time_zone("America/New_York").to_date
      prices = %w[open high low close].to_h do |key|
        value = BigDecimal(quotes.fetch(key).fetch(index).to_s)
        raise ArgumentError, "Invalid SPY price" unless value.finite? && value.positive?
        [key.to_sym, value]
      end
      unless prices[:high] >= [prices[:open], prices[:close], prices[:low]].max && prices[:low] <= [prices[:open], prices[:close]].min
        raise ArgumentError, "Invalid SPY candle bounds"
      end
      volume = Integer(quotes.fetch("volume").fetch(index))
      raise ArgumentError, "Invalid SPY volume" if volume.negative?
      prices.merge(date: date, reference_volume: volume)
    end.sort_by { |row| row[:date] }
    raise ArgumentError, "Duplicate dates" unless rows.map { |r| r[:date] }.uniq.size == rows.size
    raise ArgumentError, "Insufficient SPY history" if rows.empty? || rows.first[:date] > (as_of << 24).beginning_of_week

    instrument.with_lock do
      native = instrument.candles.where(data_source: "t_invest")
      first_day = native.where(timeframe: "day").minimum(:time)&.to_date
      first_week = native.where(timeframe: "week").minimum(:time)&.to_date
      raise ArgumentError, "Load the real SP500F history first" unless first_day && first_week
      by_date = rows.index_by { |row| row[:date] }
      differences = native.where(timeframe: "day").filter_map do |candle|
        reference = by_date[candle.time.to_date]
        ((candle.close / reference[:close] - 1) * 100).abs.to_f if reference
      end
      if differences.size < 10 || differences.max > 2
        raise ArgumentError, "SPY/SP500F overlap is insufficient or differs by more than 2%"
      end
      raise ArgumentError, "Missing history at the join" unless rows.last[:date] >= first_day

      daily = rows.select { |row| row[:date] >= (as_of << 12) && row[:date] < first_day }
      # Build complete source weeks before the first real SP500F week. Never mix sources within a week.
      weekly = rows.group_by { |row| row[:date].beginning_of_week }.filter_map do |week, bars|
        next unless week >= (as_of << 24).beginning_of_week && week < first_week && week + 7 <= as_of
        { date: week, open: bars.first[:open], high: bars.map { |r| r[:high] }.max,
          low: bars.map { |r| r[:low] }.min, close: bars.last[:close],
          reference_volume: bars.sum { |r| r[:reference_volume] } }
      end
      added = { "day" => daily, "week" => weekly }.each_with_object({}) do |(timeframe, bars), result|
        records = bars.map do |bar|
          bar.except(:date).merge(instrument_id: instrument.id, timeframe: timeframe,
            time: Time.utc(bar[:date].year, bar[:date].month, bar[:date].day),
            volume: nil, data_source: "yahoo_spy")
        end
        result[timeframe] = records.empty? ? 0 : Candle.insert_all(records, unique_by: [:instrument_id, :timeframe, :time], returning: %w[id]).rows.size
      end
      %w[day week].each do |timeframe|
        candles = instrument.candles.where(timeframe: timeframe).order(:time).to_a
        LevelBuilder.call(instrument: instrument, timeframe: timeframe, candles: candles)
      end
      { added: added, overlap_days: differences.size, max_difference_percent: differences.max.round(4) }
    end
  end
end
