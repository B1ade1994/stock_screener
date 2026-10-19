require 'rails_helper'

RSpec.describe TechnicalContext do
  let(:instrument) { create_instrument }
  around { |e| travel_to(Time.zone.local(2026, 10, 16, 12)) { e.run } }

  def candle(time, price, timeframe: 'day')
    instrument.candles.create!(time: time, timeframe: timeframe, data_source: 't_invest',
      open: price, close: price, high: price + 1, low: price - 1, volume: 100)
  end

  def history
    60.times { |i| candle((60 - i).days.ago.beginning_of_day, 100 + i) }
    45.times { |i| candle(Time.current.beginning_of_week - (45 - i).weeks, 100 + i, timeframe: 'week') }
  end

  def reversal(**overrides)
    instrument.signals.create!({kind: 'reversal', title: 'Reversal', event_key: SecureRandom.uuid, occurred_at: Time.current,
      details: { direction: 'up', entry_price: '161', extreme: '159', volatility: '1',
        rebound_boundary: '161.5', last_checked_at: 1.minute.ago.iso8601 }}.merge(overrides))
  end

  it 'uses only completed daily/weekly bars and freezes zone distances and the original risk boundary' do
    history
    support = create_strong_level(instrument, side: 'support', price: 159, lower_price: 158, upper_price: 160)
    resistance = create_strong_level(instrument, price: 165, lower_price: 164, upper_price: 166)
    candle(Time.current.beginning_of_day, 2000)
    candle(Time.current.beginning_of_week, 3000, timeframe: 'week')
    signal = reversal
    context = signal.details.fetch('technical_context')
    expect(context).to include('direction' => 'up', 'alignment' => 'with_trend', 'location' => 'near_support', 'daily_atr' => 2.0)
    expect(context['daily']).to include('direction' => 'up', 'close' => 159.0)
    expect(context['weekly']).to include('direction' => 'up', 'close' => 144.0)
    expect(context['support']).to include('id' => support.id, 'distance_atr' => 0.5)
    expect(context['resistance']).to include('id' => resistance.id, 'distance_atr' => 1.5)
    expect(context['room_risk']).to be_within(0.00001).of(3 / 2.1)
    frozen = context.deep_dup
    resistance.update!(lower_price: 162)
    travel 1.day
    signal.update!(details: signal.details.merge('status_reason' => 'Updated later'))
    expect(signal.reload.details['technical_context']).to eq(frozen)
  end

  it 'does not infer a trend, room or distance in ATR without enough data' do
    signal = reversal
    expect(signal.details['technical_context']).to include('location' => 'unknown', 'alignment' => 'unknown',
      'daily_atr' => nil, 'room_risk' => nil, 'opposing_room_percent' => nil)
    expect(signal.details.dig('technical_context', 'daily', 'direction')).to eq('unknown')
  end

  it 'excludes an unfinished UTC daily bar just after Moscow midnight' do
    travel_to Time.zone.local(2026, 10, 16, 1)
    candle(Time.zone.local(2026, 10, 15, 3), 999) # Its 24-hour interval has not ended.
    signal = reversal
    expect(signal.details.dig('technical_context', 'daily', 'bars')).to eq(0)
    expect(signal.details.dig('technical_context', 'daily_atr')).to be_nil
  end

  it 'uses the first volume candle rather than later episode direction and describes its wick' do
    signal = instrument.signals.create!(kind: 'volume', title: 'Volume', event_key: 'first-price', occurred_at: Time.current,
      episode_direction: 'sell', details: { bursts: [{ open_price: '100', close_price: '101', high_price: '105', low_price: '99', ratio: 5 }] })
    context = signal.details.fetch('technical_context')
    expect(context['direction']).to eq('up')
    expect(context['candle']).to include('shape' => 'upper_wick', 'relative_volume' => 5)
    signal.update!(details: signal.details.merge('price_direction' => 'down', 'price_close' => '90'))
    expect(signal.reload.details['technical_context']).to eq(context)
  end

  it 'captures each derived decision independently instead of inheriting a parent study' do
    parent = reversal
    child = instrument.signals.create!(kind: 'directional_hint', title: 'Child', event_key: 'child', occurred_at: Time.current,
      details: parent.details.merge('price' => '162', 'source_signal_id' => parent.id))
    expect(child.details.dig('technical_context', 'price').to_d).to eq(162)
    expect(child.details).not_to have_key('technical_study')
    expect(parent.details['technical_study']['status']).to eq('pending')
  end

  it 'does not add a context to a legacy event later or substitute the current quote for missing prices' do
    signal = instrument.signals.create!(kind: 'volume', title: 'Legacy', event_key: 'legacy', occurred_at: 1.day.ago)
    instrument.update!(last_price: 999)
    signal.update!(title: 'Updated')
    expect(signal.reload.details).to eq({})
  end
end
