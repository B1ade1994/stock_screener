require 'rails_helper'

RSpec.describe IntradayLevelBreakout do
  let(:instrument) { create_instrument(kind: 'futures') }
  let(:period) { Time.current.utc.beginning_of_day }
  around { |example| travel_to(Time.zone.local(2026, 10, 23, 12)) { example.run } }

  def prepare(side: 'support')
    20.times do |n|
      instrument.candles.create!(timeframe: 'day', time: period - (20 - n).days,
        open: 101, high: 102, low: 100, close: 101, volume: 100)
    end
    @source = instrument.price_levels.create!(source: 'automatic', status: 'confirmed', timeframe: 'day',
      side: side, price: 101, lower_price: 100, upper_price: 102, touches: 2,
      created_at: period - 1.day, assessment: { 'version' => 2, 'score' => 30, 'as_of' => (period - 1.day).iso8601 })
    @target = instrument.price_levels.create!(source: 'automatic', status: 'confirmed', timeframe: 'day',
      side: side, price: side == 'support' ? 89 : 111,
      lower_price: side == 'support' ? 88 : 110, upper_price: side == 'support' ? 90 : 112,
      touches: 2, created_at: period - 1.day,
      assessment: { 'version' => 2, 'score' => 10, 'as_of' => (period - 1.day).iso8601 })
    instrument.price_levels.create!(source: 'automatic', status: 'confirmed', timeframe: 'day',
      side: 'resistance', price: 200, touches: 2, created_at: period - 1.day,
      assessment: { 'version' => 2, 'score' => 20, 'as_of' => (period - 1.day).iso8601 })
    closes = side == 'support' ? [100, 99.6, 99.4] : [102, 102.4, 102.6]
    instrument.update!(last_price: closes.last, last_trade_at: 5.seconds.ago,
      intraday_breakout_state: { 'enabled' => true, 'started_at' => 20.minutes.ago.iso8601,
        'last_minute_at' => 10.minutes.ago.iso8601 })
    closes.each_with_index.map do |close, n|
      described_class::Minute.new(time: (4 - n).minutes.ago, open: close.to_d,
        high: close.to_d + 0.2, low: close.to_d - 0.2, close: close.to_d, volume: 100)
    end
  end

  it 'registers a fresh short with frozen stop and structural target, and measures only after notification' do
    minutes = prepare
    described_class.process(instrument, minutes, now: Time.current)
    signal = instrument.signals.where(kind: described_class::KIND).sole
    expect(signal).to have_attributes(reversal_status: 'confirmed', confirmed_at: Time.current, research_only: true)
    expect(signal.details).to include('direction' => 'down', 'stop' => '102.2', 'target' => '90.0')
    expect(signal.reaction.reference_at).to eq(1.minute.from_now)
    expect(signal.confirmation_reaction).to be_nil
    frozen = signal.details.deep_dup
    @target.update!(upper_price: 91)
    described_class.process(instrument, minutes, now: Time.current)
    expect(signal.reload.details).to eq(frozen)
    expect(instrument.signals.where(kind: described_class::KIND).count).to eq(1)
  end

  it 'registers the mirrored long without waiting for a daily candle or retest' do
    described_class.process(instrument, prepare(side: 'resistance'), now: Time.current)
    signal = instrument.signals.where(kind: described_class::KIND).sole
    expect(signal.details).to include('direction' => 'up', 'stop' => '99.8', 'target' => '110.0')
    expect(signal.title).to include('лонг')
  end

  it 'does not use evidence from before activation, stale quotes or unfinished source levels' do
    minutes = prepare
    original = instrument.intraday_breakout_state
    instrument.update!(intraday_breakout_state: original.merge('started_at' => 3.minutes.ago.iso8601))
    described_class.process(instrument, minutes, now: Time.current)
    expect(instrument.signals).to be_empty
    instrument.update!(intraday_breakout_state: original, last_trade_at: 3.minutes.ago)
    described_class.process(instrument, minutes, now: Time.current)
    expect(instrument.signals).to be_empty
    instrument.update!(intraday_breakout_state: original, last_trade_at: Time.current)
    @source.update!(assessment: @source.assessment.merge('as_of' => period.iso8601))
    described_class.process(instrument, minutes, now: Time.current)
    expect(instrument.signals).to be_empty
  end

  it 'does not bridge missing minutes or manufacture an idea from an old crossing' do
    minutes = prepare
    minutes[1].time -= 10.seconds
    described_class.process(instrument, minutes, now: Time.current)
    expect(instrument.signals).to be_empty
    instrument.update!(intraday_breakout_state: instrument.intraday_breakout_state.merge('last_minute_at' => 10.minutes.ago.iso8601))
    minutes.each { |bar| bar.time -= 10.minutes }
    described_class.process(instrument, minutes, now: Time.current)
    expect(instrument.signals).to be_empty
  end

  it 'suppresses a new crossing of the same zone for six hours' do
    minutes = prepare
    described_class.process(instrument, minutes, now: Time.current)
    travel 5.minutes
    instrument.update!(last_trade_at: Time.current)
    fresh = minutes.map { |bar| described_class::Minute.new(**bar.to_h.merge(time: bar.time + 5.minutes)) }
    expect { described_class.process(instrument, fresh, now: Time.current) }.not_to change(MarketSignal, :count)
  end

  it 'establishes a baseline without fetching old crossings and resets it when re-enabled' do
    client = instance_double(TInvest::Client)
    expect(client).not_to receive(:minute_candles)
    described_class.call(instrument, client: client)
    expect(instrument.reload.intraday_breakout_state['started_at']).to eq(Time.current.iso8601)
    instrument.update!(breakout_enabled: false)
    described_class.call(instrument, client: client)
    expect(instrument.reload.intraday_breakout_state['enabled']).to be false
    travel 1.minute
    instrument.update!(breakout_enabled: true)
    described_class.call(instrument, client: client)
    expect(instrument.reload.intraday_breakout_state['started_at']).to eq(Time.current.iso8601)
  end

  it 'fetches only a bounded completed-minute window' do
    minutes = prepare
    client = instance_double(TInvest::Client)
    expect(client).to receive(:minute_candles).with(instrument.uid,
      from: (Time.current - 95.seconds).beginning_of_minute - 15.minutes,
      to: (Time.current - 95.seconds).beginning_of_minute + 1.minute) do
      minutes.map(&:to_h)
    end
    described_class.call(instrument, client: client)
    expect(instrument.signals.where(kind: described_class::KIND).count).to eq(1)
  end
end
