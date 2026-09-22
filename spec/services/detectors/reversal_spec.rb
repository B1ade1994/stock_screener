require 'rails_helper'
require_relative '../../support/reversal_helpers'

RSpec.describe Detectors::Reversal do
  include ReversalHelpers
  around { |example| travel_to(Time.zone.local(2026, 9, 22, 14)) { example.run } }

  it 'detects a rebound after a sharp drop and its mirrored sell-off with identical strength' do
    up = described_class.evaluate(bars: reversal_bars)
    down = described_class.evaluate(bars: reversal_bars(direction: 'down'))
    expect(up).to include(direction: 'up', scenario: 'sharp', impulse_minutes: 5, relative_volume: 2.0)
    expect(down).to include(direction: 'down', scenario: 'sharp', impulse_minutes: 5, relative_volume: 2.0)
    expect(up[:impulse_percent]).to eq(-down[:impulse_percent])
    expect(up[:retracement_percent]).to eq(down[:retracement_percent])
  end

  it 'detects hour-long directional movement followed by a rebound' do
    expect(described_class.evaluate(bars: reversal_bars(minutes: 60))).to include(scenario: 'sustained', impulse_minutes: 60)
  end

  it 'rejects gaps, incomplete minutes and old minutes without OHLC' do
    [->(b) { b.time -= 60 }, ->(b) { b.complete = false }, ->(b) { b.low_price = nil }].each do |corrupt|
      bars = reversal_bars
      corrupt.call(bars[10])
      expect(described_class.evaluate(bars: bars)).to be_nil
    end
  end

  it 'accepts validated complete minutes across connections' do
    bars = reversal_bars(minutes: 60)
    bars.last(20).each { |bar| bar.session = SecureRandom.uuid }
    expect(described_class.evaluate(bars: bars)).to include(impulse_minutes: 60)
  end

  it 'does not combine two calendar days or accept an insufficient baseline' do
    expect(described_class.evaluate(bars: reversal_bars(at: Time.current.beginning_of_day + 5.minutes))).to be_nil
    expect(described_class.evaluate(bars: reversal_bars.drop(1))).to be_nil
  end

  it 'rejects low volume and a rebound that sets a fresh low' do
    bars = reversal_bars
    bars.last(3).each { |b| b.buy = b.sell = 50 }
    expect(described_class.evaluate(bars: bars)).to be_nil
    bars = reversal_bars
    bars.last.low_price = 98
    expect(described_class.evaluate(bars: bars)).to be_nil
  end

  it 'rejects an isolated green candle and a zero-volatility baseline' do
    bars = reversal_bars
    bars[-2].close_price = bars[-3].close_price - 0.01
    expect(described_class.evaluate(bars: bars)).to be_nil
    bars = reversal_bars
    bars.first(20).each { |b| b.high_price = b.low_price = 100 }
    expect(described_class.evaluate(bars: bars)).to be_nil
  end

  it 'requires the prior move to exceed ordinary volatility, not just a fixed percentage' do
    bars = reversal_bars
    bars.first(20).each { |b| b.high_price = 101; b.low_price = 99 }
    expect(described_class.evaluate(bars: bars)).to be_nil
  end
end
