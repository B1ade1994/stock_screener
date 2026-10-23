require 'rails_helper'

RSpec.describe LevelBreakoutSetup do
  def zone(id, side:, lower:, upper:)
    PriceLevel.new(id: id, side: side, timeframe: 'day', lower_price: lower, upper_price: upper,
      price: (lower + upper) / 2.0, touches: 2, assessment: { 'as_of' => '2026-10-20T00:00:00Z', 'score' => 30 })
  end

  def minute(offset, close)
    IntradayLevelBreakout::Minute.new(time: Time.utc(2026, 10, 23, 8) + offset.minutes,
      open: close.to_d, high: close.to_d + 0.2, low: close.to_d - 0.2, close: close.to_d)
  end

  def setup(side: 'support', price: nil, levels: nil, closes: nil, atr: 2)
    @source = zone(1, side: side, lower: 100, upper: 102)
    @target = zone(2, side: side, lower: side == 'support' ? 88 : 110, upper: side == 'support' ? 90 : 112)
    closes ||= side == 'support' ? [100, 99.6, 99.4] : [102, 102.4, 102.6]
    described_class.start(@source, levels: levels || [@source, @target],
      previous: minute(0, closes[0]), first: minute(1, closes[1]), second: minute(2, closes[2]),
      price: (price || closes.last).to_d, atr: atr)
  end

  it 'places a short stop above the entire support and targets the next support, freezing geometry' do
    s = setup
    expect(s).to include('direction' => 'down', 'target' => '90.0', 'stop' => '102.2')
    expect(s['room_risk']).to be > 1.5
    @target.upper_price = 999
    @source.upper_price = 999
    expect(s.values_at('target', 'stop')).to eq(%w[90.0 102.2])
  end

  it 'mirrors the trigger, stop and nearest resistance target for a long' do
    s = setup(side: 'resistance')
    expect(s).to include('direction' => 'up', 'target' => '110.0', 'stop' => '99.8')
    expect(s['target_zone']['side']).to eq('resistance')
  end

  it 'rejects a wick, a single qualifying close, an old crossing and a return of the current price' do
    expect(setup(closes: [100, 99.9, 99.4])).to be_nil
    expect(setup(closes: [100, 99.6, 100])).to be_nil
    expect(setup(closes: [99.6, 99.5, 99.4])).to be_nil
    expect(setup(price: 100)).to be_nil
    expect(setup(side: 'resistance', price: 102)).to be_nil
  end

  it 'rejects chasing on either side and insufficient reward relative to the frozen stop' do
    expect(setup(price: 98.9)).to be_nil
    expect(setup(side: 'resistance', price: 103.1)).to be_nil
    close_target = zone(3, side: 'support', lower: 97, upper: 98)
    expect(setup(levels: [close_target])).to be_nil
  end

  it 'uses the closest confirmed obstacle rather than skipping it for a farther target' do
    nearer = zone(3, side: 'support', lower: 93, upper: 94)
    farther = zone(4, side: 'support', lower: 80, upper: 82)
    expect(setup(levels: [farther, nearer])['target']).to eq('94.0')
    containing = zone(5, side: 'support', lower: 99, upper: 100)
    expect(setup(levels: [farther, containing])).to be_nil
    expect(setup(levels: [])).to be_nil
  end

  it 'requires contiguous valid completed evidence and an ATR' do
    source = zone(1, side: 'support', lower: 100, upper: 102)
    args = { levels: [], previous: minute(0, 100), first: minute(2, 99.6), second: minute(3, 99.4), price: 99.4.to_d, atr: 2 }
    expect(described_class.start(source, **args)).to be_nil
    expect(setup(atr: nil)).to be_nil
  end
end
