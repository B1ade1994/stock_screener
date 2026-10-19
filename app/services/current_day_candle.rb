# Unfinished snapshots stay outside Candle history. Used by the chart and the
# explicitly intraday experiment; completed-day calculations never consume them.
class CurrentDayCandle
  TTL = 15.seconds

  def self.key(instrument, now)
    [name, instrument.uid, now.utc.to_date.iso8601]
  end

  def self.cached(instrument, now: Time.current)
    decorate(instrument, Rails.cache.read(key(instrument, now)), now: now)
  end

  def self.call(instrument, now: Time.current, client: TInvest::Client.new)
    snapshot = Rails.cache.fetch(key(instrument, now), expires_in: TTL) do
      begin
        raw = client.current_day_candle(instrument.uid, now: now)
        if raw
          { 'time' => raw.fetch('time'), 'volume' => Integer(raw.fetch('volume')),
            'captured_at' => now.iso8601(6) }.merge(%w[open high low close].to_h { |field|
              [field, TInvest::Client.number(raw.fetch(field)).to_f]
            })
        end
      rescue TInvest::Error, KeyError, ArgumentError
        # Keep quote polling usable while the candle API is unavailable. Cache the
        # failed attempt briefly too, rather than retrying on every browser poll.
        nil
      end
    end
    decorate(instrument, snapshot, now: now)
  end

  def self.decorate(instrument, snapshot, now:)
    return unless snapshot && Time.iso8601(snapshot.fetch('time')) == now.utc.beginning_of_day
    bar = snapshot.deep_dup
    values = %w[open high low close].map { |field| bar.fetch(field) }
    return unless values.all? { |value| value.finite? && value.positive? } && bar['volume'] >= 0
    return unless bar['high'] >= values.max && bar['low'] <= values.min

    # The API candle has no last-trade timestamp. Use the same fresh exchange
    # quote as the price marker, so the forming close stays consistent with it.
    traded_at = instrument.last_trade_at
    if traded_at && traded_at >= now - 2.minutes && traded_at <= now &&
        traded_at >= now.utc.beginning_of_day && instrument.last_price&.positive?
      bar['close'] = instrument.last_price.to_f
      bar['high'] = [bar['high'], bar['close']].max
      bar['low'] = [bar['low'], bar['close']].min
    end
    bar.merge('date' => now.utc.beginning_of_day.in_time_zone.strftime('%d.%m.%Y'))
  end
  private_class_method :decorate
end
