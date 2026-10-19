require 'rails_helper'

RSpec.describe DailySupportBounceSetup do
  let(:zone) { DailyRetestLevels::Zone.new(side: 'support', timeframe: 'week', lower_price: 10996.258, upper_price: 11618.71, touches: 2, assessment: { 'score' => 2.38, 'as_of' => '2026-10-05' }) }
  let(:weekly) { { 'as_of' => '2026-10-05', 'ema' => { 40 => 11071.625 } } }
  def bar(day, opening:, close:, low:, high: [opening, close].max)
    Candle.new(time: Time.utc(2026, 10, day), open: opening, high: high, low: low, close: close)
  end
  def setup
    described_class.start(zone, previous: bar(13, opening: 11319, close: 11279, low: 11226.5),
      bar: bar(14, opening: 11262.5, close: 10993.5, low: 10990.5, high: 11277), atr: 213.5859, weekly: weekly)
  end

  it 'recognizes the GLDRUB_TOM 14–15 October return without requiring a resistance breakout or a closed current week' do
    s = setup
    expect(s).to include('status' => 'possible', 'near_weekly_ema40' => true, 'bars' => 0)
    zone.lower_price = 12000
    result = described_class.advance(s, bar(15, opening: 11100, close: 11211.5, low: 11095.5, high: 11260))
    expect(result).to include('status' => 'confirmed', 'ema40_reclaimed' => true)
    expect(result['stop'].to_d).to be_within(0.001).of(10969.14141)
    expect(s['status']).to eq('possible')
    expect(result['lower'].to_d).to be_within(0.001).of(10996.258)
  end
  it 'requires an approach from above to the lower edge of a support, not a touch in the middle of a broad zone' do
    b = bar(14, opening: 11300, close: 11320, low: 11250)
    expect(described_class.start(zone, previous: b, bar: b, atr: 200, weekly: weekly)).to be_nil
    zone.side = 'resistance'
    expect(setup).to be_nil
    zone.side = 'support'
    expect(described_class.start(zone, previous: bar(13, opening: 10900, close: 10900, low: 10890), bar: b, atr: 200, weekly: weekly)).to be_nil
  end
  it 'rejects deep breaks and unknown ATR but treats missing EMA history as unknown instead of a veto' do
    b = bar(14, opening: 11200, close: 10900, low: 10800)
    expect(described_class.start(zone, previous: b, bar: b, atr: 200, weekly: weekly)).to be_nil
    expect(described_class.start(zone, previous: b, bar: b, atr: nil, weekly: weekly)).to be_nil
    weekly.clear
    expect(setup).to include('near_weekly_ema40' => false, 'weekly_ema40' => nil)
  end
  it 'cancels a renewed low before a favorable same-day close and never revives a terminal setup' do
    cancelled = described_class.advance(setup, bar(15, opening: 11100, close: 11300, low: 10950))
    expect(cancelled['status']).to eq('cancelled')
    expect(described_class.advance(cancelled, bar(16, opening: 11100, close: 11300, low: 11100))).to eq(cancelled)
  end
  it 'requires a bullish close, a higher low and a buffered return, and expires after three bars' do
    s = setup
    3.times { |n| s = described_class.advance(s, bar(15 + n, opening: 11050, close: 11000, low: 10995)) }
    expect(s['status']).to eq('expired')
    expect(described_class.advance(setup, bar(15, opening: 11100, close: 11200, low: 10985))['status']).to eq('possible')
    expect(described_class.advance(setup, bar(15, opening: 11200, close: 11150, low: 11000))['status']).to eq('possible')
  end
end
