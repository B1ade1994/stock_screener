require 'rails_helper'

RSpec.describe IntradaySupportBounce do
  let(:instrument) { create_instrument(kind: 'futures') }
  let(:period) { Time.current.utc.beginning_of_day }
  let(:snapshot) { { 'time' => period.iso8601, 'open' => 103.0, 'high' => 104.0, 'low' => 99.5, 'close' => 102.0, 'volume' => 1000 } }

  around { |example| travel_to(Time.zone.local(2026, 10, 19, 12)) { example.run } }

  def bar(time, opening: 101, close: 102, low: 100.5)
    described_class::Minute.new(time: time, open: opening.to_d, high: [opening, close, 103].max.to_d,
      low: low.to_d, close: close.to_d, volume: 100)
  end

  def prepare
    20.times do |n|
      instrument.candles.create!(timeframe: 'day', time: period - (20 - n).days,
        open: 103, high: 104, low: 102, close: 103, volume: 100)
    end
    create_strong_level(instrument, side: 'support', price: 101, lower_price: 100, upper_price: 102,
      assessment: { 'version' => Detectors::Levels::VERSION, 'score' => 30, 'as_of' => (period - 1.day).iso8601 })
    instrument.price_levels.each do |level|
      level.update!(assessment: level.assessment.merge('as_of' => (period - 1.day).iso8601))
    end
    instrument.update!(intraday_bounce_state: { 'enabled' => true, 'started_at' => 20.minutes.ago.iso8601,
      'last_minute_at' => 10.minutes.ago.iso8601 })
    # Daily ATR is 2, so holding must close above 100.2; cancellation is 99.3.
    [bar(4.minutes.ago, opening: 101, close: 100, low: 99.5), bar(3.minutes.ago), bar(2.minutes.ago)]
  end

  def create_early
    described_class.process(instrument, snapshot, prepare, now: Time.current)
    instrument.signals.find_by!(kind: described_class::KIND)
  end

  it 'registers one forming idea only after a touch and two consecutive closed minutes, freezing evidence' do
    minutes = prepare
    expect { described_class.process(instrument, snapshot, minutes.first(2), now: Time.current) }.not_to change(MarketSignal, :count)
    expect { described_class.process(instrument, snapshot, minutes, now: Time.current) }.to change(MarketSignal, :count).by(1)
    signal = instrument.signals.find_by!(kind: described_class::KIND)
    expect(signal).to have_attributes(reversal_status: 'forming', confirmed_at: nil, research_only: true)
    expect(signal.details).to include('stop' => a_string_starting_with('99.3'), 'confirmation_boundary' => a_string_starting_with('100.2'))
    frozen = signal.details.deep_dup
    expect(signal.reactions).to be_empty
    travel 1.minute
    described_class.process(instrument, snapshot.merge('close' => 103), [bar(2.minutes.ago)], now: Time.current)
    expect(signal.reload.details).to eq(frozen)
    expect(instrument.signals.where(kind: described_class::KIND).count).to eq(1)
  end

  it 'does not bridge gaps, accept a bare touch, reuse pre-activation minutes or unfinished zones' do
    minutes = prepare
    instrument.update!(intraday_bounce_state: instrument.intraday_bounce_state.merge('started_at' => 3.minutes.ago.iso8601))
    described_class.process(instrument, snapshot, minutes, now: Time.current)
    expect(instrument.signals.where(kind: described_class::KIND)).to be_empty
    instrument.update!(intraday_bounce_state: { 'enabled' => true, 'started_at' => 20.minutes.ago.iso8601,
      'last_minute_at' => 10.minutes.ago.iso8601 })
    minutes[1].time -= 10.seconds
    described_class.process(instrument, snapshot, minutes, now: Time.current)
    expect(instrument.signals.where(kind: described_class::KIND)).to be_empty
    instrument.price_levels.update_all(assessment: { 'score' => 30, 'as_of' => period.iso8601 })
    instrument.update!(intraday_bounce_state: instrument.intraday_bounce_state.merge('last_minute_at' => 10.minutes.ago.iso8601))
    described_class.process(instrument, snapshot, [bar(4.minutes.ago, close: 100, low: 99.5), bar(3.minutes.ago), bar(2.minutes.ago)], now: Time.current)
    expect(instrument.signals.where(kind: described_class::KIND)).to be_empty
  end

  it 'cancels on a subsequent stop breach without recreating from old evidence or rewriting it' do
    signal = create_early
    stop = signal.details['stop']
    travel 1.minute
    described_class.process(instrument, snapshot.merge('low' => 99.0), [bar(2.minutes.ago)], now: Time.current)
    expect(signal.reload.reversal_status).to eq('cancelled')
    expect(signal.confirmed_at).to be_nil
    expect(signal.details['stop']).to eq(stop)
    travel 1.minute
    described_class.process(instrument, snapshot, [bar(2.minutes.ago)], now: Time.current)
    expect(instrument.signals.where(kind: described_class::KIND).count).to eq(1)
  end

  it 'allows a fresh touch after cancellation, including legacy day-wide keys, and keeps the old idea cancelled' do
    original = create_early
    original.update!(event_key: "intraday-support-bounce:v1:#{instrument.id}:#{period.to_i}")
    travel 1.minute
    lower_snapshot = snapshot.merge('low' => 99.0)
    described_class.process(instrument, lower_snapshot, [bar(2.minutes.ago)], now: Time.current)
    original.reload
    frozen = original.attributes.deep_dup
    ended_at = Time.current

    # A touch before cancellation cannot be reused even if its holding minutes
    # and the polling cursor are newer.
    travel 3.minutes
    stale_touch = [bar(ended_at - 1.minute, close: 100, low: 99),
      bar(ended_at), bar(ended_at + 1.minute)]
    expect { described_class.process(instrument, lower_snapshot, stale_touch, now: Time.current) }.not_to change(MarketSignal, :count)

    travel 2.minutes
    fresh = [bar(ended_at + 1.minute, close: 100, low: 99),
      bar(ended_at + 2.minutes), bar(ended_at + 3.minutes)]
    expect { described_class.process(instrument, lower_snapshot, fresh, now: Time.current) }.to change(MarketSignal, :count).by(1)
    replacement = instrument.signals.order(:id).last
    expect(replacement.reversal_status).to eq('forming')
    expect(replacement.details['early_evidence'].first['time']).to eq(fresh.first.time.iso8601)
    expect(replacement.details['stop'].to_d).to eq(98.8.to_d)
    expect(replacement.event_key).not_to eq(original.event_key)
    expect(original.reload.attributes).to eq(frozen)

    expect { described_class.process(instrument, lower_snapshot, fresh, now: Time.current) }.not_to change(MarketSignal, :count)
    travel 1.minute
    expect { described_class.process(instrument, lower_snapshot, [bar(2.minutes.ago)], now: Time.current) }.not_to change(MarketSignal, :count)
  end

  it 'requires fresh evidence after expiry too' do
    signal = create_early
    travel 10.minutes
    described_class.process(instrument, snapshot, [bar(2.minutes.ago)], now: Time.current)
    expect(signal.reload.reversal_status).to eq('expired')
    travel 5.minutes
    fresh = [bar(4.minutes.ago, close: 100, low: 99.5), bar(3.minutes.ago), bar(2.minutes.ago)]
    expect { described_class.process(instrument, snapshot, fresh, now: Time.current) }.to change(MarketSignal, :count).by(1)
    expect(signal.reload.reversal_status).to eq('expired')
  end

  it 'does not confirm from the live candle and confirms the same record only after the completed daily candle arrives' do
    signal = create_early
    described_class.reconcile(instrument, now: Time.current)
    expect(signal.reload.confirmed_at).to be_nil
    instrument.candles.create!(timeframe: 'day', time: period, open: 101, high: 104, low: 99.5, close: 103, volume: 1000)
    described_class.reconcile(instrument, now: Time.current)
    expect(signal.reload.confirmed_at).to be_nil
    travel 1.day
    described_class.reconcile(instrument, now: Time.current)
    expect(signal.reload.reversal_status).to eq('confirmed')
    expect(signal.confirmed_at).to eq(Time.current)
    expect(signal.details).not_to have_key('entry_price')
    expect(signal.details['early_price']).to eq('102.0')
    expect(signal.details['outcomes']).to eq({})
    expect(instrument.signals.where(kind: described_class::KIND).count).to eq(1)
  end

  it 'expires an unconfirmed day without assigning a trade result' do
    signal = create_early
    instrument.candles.create!(timeframe: 'day', time: period, open: 103, high: 104, low: 99.5, close: 101, volume: 1000)
    travel 1.day
    described_class.reconcile(instrument, now: Time.current)
    expect(signal.reload.reversal_status).to eq('expired')
    expect(signal.confirmed_at).to be_nil
  end

  it 'prioritizes a stop breach over a favorable daily close' do
    signal = create_early
    instrument.candles.create!(timeframe: 'day', time: period, open: 101, high: 104, low: 99, close: 103, volume: 1000)
    travel 1.day
    described_class.reconcile(instrument, now: Time.current)
    expect(signal.reload.reversal_status).to eq('cancelled')
    expect(signal.confirmed_at).to be_nil
  end

  it 'expires missing or delayed confirmation instead of backdating an entry' do
    signal = create_early
    travel 2.days
    described_class.reconcile(instrument, now: Time.current)
    expect(signal.reload.reversal_status).to eq('expired')
    expect(signal.details['status_reason']).to include('не поступила')
    expect(signal.confirmed_at).to be_nil
  end

  it 'cancels on a minute close back under support even when the daily stop is intact' do
    signal = create_early
    travel 3.minutes
    described_class.process(instrument, snapshot, [bar(2.minutes.ago, close: 99.7, low: 99.5)], now: Time.current)
    expect(signal.reload.reversal_status).to eq('cancelled')
    expect(signal.details['status_reason']).to include('Минутное закрытие')
  end

  it 'uses bounded complete minute data and live OHLC independently of browser polling' do
    minutes = prepare
    client = instance_double(TInvest::Client)
    expect(CurrentDayCandle).to receive(:call).with(instrument, now: Time.current, client: client).and_return(snapshot)
    expect(client).to receive(:minute_candles).with(instrument.uid, from: (Time.current - 95.seconds).beginning_of_minute - 15.minutes,
      to: (Time.current - 95.seconds).beginning_of_minute + 1.minute).and_return(minutes.map(&:to_h))
    before = instrument.candles.count
    described_class.call(instrument, client: client)
    expect(instrument.signals.where(kind: described_class::KIND, reversal_status: 'forming').count).to eq(1)
    expect(instrument.candles.count).to eq(before)
  end

  it 'does not skip missing monitoring minutes and later claim a confirmed daily idea' do
    signal = create_early
    travel 10.minutes
    described_class.process(instrument, snapshot, [bar(2.minutes.ago)], now: Time.current)
    expect(signal.reload.reversal_status).to eq('expired')
    expect(signal.details['status_reason']).to include('Пропуск минут контроля')
    expect(signal.confirmed_at).to be_nil
  end

  it 'establishes a baseline at activation and cancels forming ideas when monitoring is disabled' do
    expect { described_class.call(instrument) }.not_to change(MarketSignal, :count)
    expect(instrument.reload.intraday_bounce_state['started_at']).to eq(Time.current.iso8601)
    signal = create_early
    instrument.update!(breakout_enabled: false)
    described_class.call(instrument)
    expect(signal.reload.reversal_status).to eq('cancelled')
    expect(instrument.reload.intraday_bounce_state['enabled']).to eq(false)
  end

  it 'does not confirm a forming idea when monitoring was disabled before processing the closed day' do
    signal = create_early
    instrument.candles.create!(timeframe: 'day', time: period, open: 101, high: 104, low: 99.5, close: 103, volume: 1000)
    instrument.update!(enabled: false)
    travel 1.day
    described_class.call(instrument)
    expect(signal.reload.reversal_status).to eq('cancelled')
    expect(signal.confirmed_at).to be_nil
  end
end
