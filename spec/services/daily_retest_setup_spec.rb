require 'rails_helper'

RSpec.describe DailyRetestSetup do
  let(:zone) { DailyRetestLevels::Zone.new(side: 'resistance', timeframe: 'day', lower_price: 98, upper_price: 100, touches: 3, assessment: { 'score' => 7, 'as_of' => '2026-10-01' }) }
  def bar(close:, low: close - 1, high: close + 1)
    Candle.new(time: Time.utc(2026, 10, 7), open: close, high: high, low: low, close: close)
  end
  def setup
    described_class.start(zone, previous: bar(close: 99), bar: bar(close: 102, low: 99), atr: 2)
  end

  it 'freezes the pre-breakout zone and starts with no same-bar confirmation' do
    s = setup
    zone.upper_price = 999
    expect(s).to include('status' => 'possible', 'bars' => 0, 'upper' => '100')
    result = described_class.advance(s, bar(close: 103, low: 100))
    expect(result['status']).to eq('confirmed')
    expect(result['stop'].to_d).to eq(97.8)
    expect(s['status']).to eq('possible')
  end
  it 'requires a crossing beyond the buffer and valid ATR' do
    expect(described_class.start(zone, previous: bar(close: 99), bar: bar(close: 100.1), atr: 2)).to be_nil
    expect(described_class.start(zone, previous: bar(close: 101), bar: bar(close: 103), atr: 2)).to be_nil
    expect(described_class.start(zone, previous: bar(close: 99), bar: bar(close: 102), atr: nil)).to be_nil
  end
  it 'cancels a close in the zone before checking a retest' do
    expect(described_class.advance(setup, bar(close: 99, low: 97, high: 104))['status']).to eq('cancelled')
  end
  it 'allows the fifth bar, but expires with no retest and rejects a sixth bar' do
    s = setup
    4.times { s = described_class.advance(s, bar(close: 104, low: 102)) }
    expect(described_class.advance(s, bar(close: 103, low: 100))['status']).to eq('confirmed')
    expired = described_class.advance(s, bar(close: 104, low: 102))
    expect(expired['status']).to eq('expired')
    expect(described_class.advance(expired, bar(close: 103, low: 100))['status']).to eq('expired')
  end
  it 'mirrors a short breakout, retest and stop' do
    zone.side = 'support'
    s = described_class.start(zone, previous: bar(close: 101), bar: bar(close: 96), atr: 2)
    result = described_class.advance(s, bar(close: 95, high: 98))
    expect(result).to include('status' => 'confirmed', 'direction' => 'down')
    expect(result['stop'].to_d).to eq(100.2)
  end
end
