require 'rails_helper'

RSpec.describe Detectors::ShockReversal do
  def bars(direction: 'up')
    at = Time.zone.local(2026, 9, 29, 16)
    prices = Array.new(20) { [100, 100, 100.1, 99.9, 100] }
    # Nine-minute impulse, including small counter-moves. Last two closes recover.
    [99, 98, 98.5, 97, 96, 96.5, 95, 94, 93, 94, 95].each_with_index do |close, i|
      open = prices.last[1]
      prices << [open, close, [open, close].max + 0.05, [open, close].min - 0.05, i >= 9 ? 300 : 200]
    end
    prices.each_with_index.map do |(o, c, h, l, v), i|
      o,c,h,l = 200-o,200-c,200-l,200-h if direction == 'down'
      ReversalMinute.new(time: at + i.minutes, open_price: o, close_price: c, high_price: h, low_price: l, volume: v, data_source: 't_invest')
    end
  end

  it 'detects the variable-length shock in both directions' do
    %w[up down].each do |direction|
      result = described_class.evaluate(bars: bars(direction: direction))
      expect(result).to include(direction: direction, scenario: 'shock', impulse_minutes: 9)
      expect(result[:relative_volume]).to eq(3)
    end
  end

  it 'does not infer a rebound before two completed minutes, through gaps, or from an invalid candle' do
    sample = bars
    expect(described_class.evaluate(bars: sample[0...-1])).to be_nil
    sample[-1].time += 60
    expect(described_class.evaluate(bars: sample)).to be_nil
    sample = bars;sample[-1].low_price = 120
    expect(described_class.evaluate(bars: sample)).to be_nil
  end

  it 'rejects a new extreme inside the supposed rebound and thin volume' do
    sample = bars;sample[-1].low_price = 92
    expect(described_class.evaluate(bars: sample)).to be_nil
    sample = bars;sample.last(2).each { |b| b.volume = 1 }
    expect(described_class.evaluate(bars: sample)).to be_nil
  end
end
