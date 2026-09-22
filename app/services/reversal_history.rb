class ReversalHistory
  LOOKBACK = Detectors::Reversal::WINDOWS.max + Detectors::Reversal::BASELINE + Detectors::Reversal::REBOUND

  def self.refresh(instrument, client: TInvest::Client.new, now: Time.current)
    through = (now - 95.seconds).beginning_of_minute
    from = [through - (LOOKBACK - 1).minutes, now.in_time_zone.beginning_of_day].max
    return if through < from

    # Reuse only complete, validated stream minutes, including previous sessions.
    instrument.market_minutes.where(complete: true, time: from..through)
      .where.not(time: instrument.reversal_minutes.select(:time)).order(:time, :id).each do |bar|
      ReversalMinute.record_stream(instrument, bar)
    end
    present = instrument.reversal_minutes.where(time: from..through).pluck(:time).to_set
    missing = (0...LOOKBACK).map { |i| from + i.minutes }.take_while { |time| time <= through }.reject { |time| present.include?(time) }
    unless missing.empty?
      # One bounded request per instrument; never hold its row lock over HTTP.
      candles = client.minute_candles(instrument.uid, from: missing.first, to: missing.last + 1.minute)
      rows = candles.filter_map do |candle|
        next unless candle[:time].between?(missing.first, missing.last) && candle[:volume]
        attributes = { instrument_id: instrument.id, time: candle[:time], volume: candle[:volume], data_source: 't_invest', source_session: nil }
          .merge(%i[open high low close].to_h { |key| ["#{key}_price".to_sym, candle.fetch(key)] })
        attributes if ReversalMinute.new(attributes).valid?
      end
      # The exchange candle wins over stream data, but never fabricates missing
      # bars or directional buy/sell volumes. Duplicate API times are collapsed.
      ReversalMinute.upsert_all(rows.index_by { |row| row[:time] }.values, unique_by: [:instrument_id, :time]) if rows.any?
    end
    instrument.update!(reversal_history_checked_at: now, reversal_history_error: nil)
    latest = instrument.reversal_minutes.where(time: from..through).order(time: :desc).first
    ReversalTracker.process(instrument, latest, recheck: true) if latest
  end
end
