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
        # Confirm only new candles formed after the level was registered.
        previous, current = candles.last(2)
        if previous && current && instrument.enabled? && instrument.breakout_enabled?
          instrument.price_levels.active.where(timeframe: timeframe).each do |level|
            next unless current.time > level.created_at
            next unless Detectors::Levels.crossed?(side: level.side, price: level.price, previous: previous.close, current: current.close)
            MarketSignal.find_or_create_by!(event_key: "confirmed:#{level.id}:#{current.time.to_i}") do |signal|
              signal.assign_attributes(instrument: instrument, kind: "confirmed", occurred_at: Time.current, title: "Пробой подтверждён: #{timeframe == 'day' ? 'дневная' : 'недельная'} свеча", details: { level: level.price.to_s, close: current.close.to_s, timeframe: timeframe, candle_time: current.time.iso8601, side: level.side })
            end
          end
        end
        Detectors::Levels.candidates(candles).each do |candidate|
          existing = instrument.price_levels.where(source: "automatic", timeframe: timeframe, side: candidate[:side]).detect { |l| (l.price.to_f - candidate[:price]).abs / candidate[:price] <= 0.003 }
          if existing
            existing.update!(touches: candidate[:touches])
          else
            instrument.price_levels.create!(candidate.merge(timeframe: timeframe, source: "automatic"))
          end
        end
      end
    end
    instrument.update!(history_synced_at: Time.current, history_error: nil)
  end
end
