require 'rails_helper'
require_relative '../support/reversal_helpers'

RSpec.describe ReversalHistory do
  include ReversalHelpers
  let(:instrument) { create_instrument(volume_enabled: true, reversal_enabled: true) }
  let(:client) { instance_double(TInvest::Client) }
  around { |example| travel_to(Time.zone.local(2026, 9, 22, 14)) { example.run } }

  def api_candle(bar)
    { time: bar.time, open: bar.open_price, high: bar.high_price, low: bar.low_price, close: bar.close_price, volume: bar.volume }
  end

  def store(bars)
    bars.each { |bar| bar.instrument = instrument; bar.save! }
  end

  it 'restores an hour-long setup across reconnects and fills a partial boundary from the API without volume alerts' do
    bars = reversal_bars(minutes: 60)
    bars.last(30).each { |bar| bar.session = SecureRandom.uuid }
    boundary = bars[53]
    boundary.complete = false
    store(bars)
    allow(client).to receive(:minute_candles).and_return([api_candle(boundary)])
    expect { described_class.refresh(instrument, client: client) }.not_to change(MarketMinute, :count)
    expect(instrument.reversal_minutes.count).to eq(83)
    signal = instrument.signals.sole
    expect(signal).to have_attributes(kind: 'reversal', reversal_status: 'possible')
    expect(signal.details).to include('version' => 2, 'impulse_minutes' => 60)
    expect(boundary.reload.complete).to be false
    expect(instrument.reversal_minutes.find_by(time: boundary.time).data_source).to eq('t_invest')
    expect { described_class.refresh(instrument, client: client) }.not_to change(MarketSignal, :count)
    expect(instrument.reversal_minutes.count).to eq(83)
  end

  it 'does not bridge a missing exchange minute with a synthetic candle' do
    bars = reversal_bars
    store(bars.reject.with_index { |_, i| i == 22 })
    allow(client).to receive(:minute_candles).and_return([])
    described_class.refresh(instrument, client: client)
    expect(instrument.signals).to be_empty
    expect(instrument.reversal_minutes.count).to eq(27)
  end

  it 'rechecks the latest live minute once recovery makes a previously incomplete window valid' do
    bars = reversal_bars
    missing = bars[22]
    store(bars - [missing])
    instrument.market_minutes.each { |bar| ReversalMinute.record_stream(instrument, bar) }
    ReversalTracker.process(instrument, bars.last)
    expect(instrument.signals).to be_empty
    expect(instrument.reload.last_reversal_minute_at).to eq(bars.last.time)
    allow(client).to receive(:minute_candles).and_return([api_candle(missing)])
    described_class.refresh(instrument, client: client)
    expect(instrument.signals.sole.kind).to eq('reversal')
  end

  it 'does not replay historical candidates or use future, malformed or volume-less candles' do
    old = reversal_bars(at: 30.minutes.ago)
    recent = reversal_bars
    invalid = api_candle(recent.last).merge(low: 0)
    allow(client).to receive(:minute_candles).and_return(old.map { |b| api_candle(b) } + [invalid,
      api_candle(recent.last).except(:volume), api_candle(recent.last).merge(time: 1.minute.from_now)])
    described_class.refresh(instrument, client: client)
    expect(instrument.reversal_minutes.count).to eq(old.size)
    expect(instrument.signals).to be_empty
  end

  it 'does not overwrite exchange volume with replayed trade snapshots or duplicate a minute' do
    bar = reversal_bars.last
    store([bar])
    allow(client).to receive(:minute_candles).and_return([api_candle(bar).merge(volume: 999)])
    # Leave a later gap so the returned exchange candle is within the requested range.
    bar.update!(complete: false)
    described_class.refresh(instrument, client: client)
    bar.update!(complete: true)
    described_class.refresh(instrument, client: client)
    expect(instrument.reversal_minutes.sole).to have_attributes(volume: 999, data_source: 't_invest')
    expect(bar.reload.volume).to eq(200)
  end

  it 'honours a switch turned off while the history request was in flight' do
    bars = reversal_bars
    allow(client).to receive(:minute_candles) do
      Instrument.find(instrument.id).update!(reversal_enabled: false)
      bars.map { |bar| api_candle(bar) }
    end
    described_class.refresh(instrument, client: client)
    expect(instrument.reversal_minutes.count).to eq(28)
    expect(instrument.signals).to be_empty
  end

  it 'does not request history when the whole current-day window is present' do
    travel_to Time.zone.local(2026, 9, 22, 0, 3)
    [0, 1].each do |minute|
      instrument.reversal_minutes.create!(time: Time.current.beginning_of_day + minute.minutes,
        open_price: 100, high_price: 101, low_price: 99, close_price: 100, volume: 100, data_source: 'stream')
    end
    expect(client).not_to receive(:minute_candles)
    described_class.refresh(instrument, client: client)
    expect(instrument.reload.reversal_history_error).to be_nil
  end

  it 'bounds requests by the Moscow calendar day, including UTC midnight' do
    travel_to Time.zone.local(2026, 9, 22, 1)
    expect(client).to receive(:minute_candles).with(instrument.uid, from: Time.current.beginning_of_day, to: Time.current - 1.minute).and_return([])
    described_class.refresh(instrument, client: client)
  end
end
