require 'rails_helper'

RSpec.describe CurrentDayCandle do
  let(:instrument) { create_instrument }
  let(:client) { instance_double(TInvest::Client) }
  let(:start) { Time.current.utc.beginning_of_day }
  let(:raw) do
    { 'time' => start.iso8601, 'isComplete' => false, 'volume' => '150' }.merge(
      %w[open high low close].zip([100, 105, 98, 102]).to_h.transform_values { |v| { 'units' => v.to_s, 'nano' => 0 } })
  end

  around do |example|
    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    travel_to(Time.zone.local(2026, 10, 19, 16)) { example.run }
  ensure
    Rails.cache = original_cache
  end

  it 'caches only display data and updates close and extremes from newer trades without writing candles or signals' do
    expect(client).to receive(:current_day_candle).once.with(instrument.uid, now: Time.current).and_return(raw)
    before_counts = [Candle.count, MarketSignal.count, PriceLevel.count]
    first = described_class.call(instrument, client: client)
    expect(first).to include('open' => 100, 'high' => 105, 'low' => 98, 'close' => 102, 'volume' => 150, 'date' => '19.10.2026')
    travel 5.seconds
    instrument.update!(last_price: 107, last_trade_at: Time.current)
    expect(described_class.call(instrument, client: client)).to include('high' => 107, 'close' => 107, 'open' => 100, 'low' => 98)
    expect([Candle.count, MarketSignal.count, PriceLevel.count]).to eq(before_counts)
    expect(described_class.cached(instrument)).to include('close' => 107)
  end

  it 'refreshes the API snapshot after the TTL and does not invent a candle when the API has none' do
    expect(client).to receive(:current_day_candle).and_return(raw)
    expect(described_class.call(instrument, client: client)).to be_present
    travel 16.seconds
    expect(client).to receive(:current_day_candle).and_return(nil)
    expect(described_class.call(instrument, client: client)).to be_nil
  end

  it 'does not use a previous-day quote or cache snapshot for the next trading day' do
    instrument.update!(last_price: 500, last_trade_at: 1.day.ago)
    allow(client).to receive(:current_day_candle).and_return(raw)
    expect(described_class.call(instrument, client: client)['close']).to eq(102)
    travel_to(start + 1.day + 1.second)
    expect(described_class.cached(instrument)).to be_nil
  end

  it 'aligns the forming close with the fresh last-trade marker, but ignores stale same-day quotes' do
    allow(client).to receive(:current_day_candle).and_return(raw)
    instrument.update!(last_price: 106, last_trade_at: 10.seconds.ago)
    expect(described_class.call(instrument, client: client)).to include('close' => 106, 'high' => 106)
    instrument.update!(last_price: 500, last_trade_at: 3.minutes.ago)
    expect(described_class.call(instrument, client: client)).to include('close' => 102, 'high' => 105)
  end

  it 'uses the candle date across the Moscow midnight boundary' do
    travel_to(Time.zone.local(2026, 10, 20, 1))
    allow(client).to receive(:current_day_candle).and_return(raw)
    expect(described_class.call(instrument, client: client)['date']).to eq('19.10.2026')
  end

  it 'briefly caches API failures and rejects malformed OHLC snapshots' do
    expect(client).to receive(:current_day_candle).once.and_raise(TInvest::Error, 'Unavailable')
    2.times { expect(described_class.call(instrument, client: client)).to be_nil }
    travel 16.seconds
    expect(client).to receive(:current_day_candle).and_return(raw.merge('high' => { 'units' => '99' }))
    expect(described_class.call(instrument, client: client)).to be_nil
  end
end
