class RefreshHistoryJob < ApplicationJob
  queue_as :default
  def perform(instrument_id = nil)
    scope = instrument_id ? Instrument.where(id: instrument_id) : Instrument.watched
    scope.find_each do |instrument|
      refresh(instrument)
    rescue TInvest::Error => error
      instrument.update!(history_error: error.message)
    end
  end
  private
  def refresh(instrument, client: TInvest::Client.new)
    %w[day week].each do |timeframe|
      rows = client.candles(instrument.uid, timeframe).map do |c|
        { instrument_id: instrument.id, timeframe: timeframe, time: Time.iso8601(c.fetch("time")), volume: c.fetch("volume").to_i }.merge(%w[open high low close].to_h { |key| [key.to_sym, TInvest::Client.number(c.fetch(key))] })
      end
      Candle.upsert_all(rows, unique_by: [:instrument_id, :timeframe, :time]) if rows.any?
      instrument.with_lock do
        candles = instrument.candles.where(timeframe: timeframe).order(:time).to_a
        LevelLifecycle.call(instrument: instrument, timeframe: timeframe, candles: candles)
        LevelBuilder.call(instrument: instrument, timeframe: timeframe, candles: candles)
      end
    end
    instrument.update!(history_synced_at: Time.current, history_error: nil)
  end
end
