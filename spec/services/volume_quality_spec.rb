require 'rails_helper'

RSpec.describe VolumeQuality do
  let(:instrument) { create_instrument }
  let(:at) { Time.current.beginning_of_minute - 2.minutes }
  let(:history) { 20.times.map { |i| MarketMinute.new(time: at - (20-i).minutes, complete: true, session: 'test', buy: 80, sell: 20, open_price: 100, close_price: 100, high_price: 100.04, low_price: 99.96) } }
  def evaluate(close, history: self.history)
    bar = MarketMinute.new(open_price: 100, close_price: close, high_price: [100, close].max, low_price: [100, close].min)
    described_class.evaluate(instrument: instrument, bar: bar, history: history)
  end
  it 'requires both the absolute threshold and half the normal true range, symmetrically' do
    expect(evaluate(100.04)).to include(passed: false, threshold_percent: 0.05, reason: 'small_move')
    expect(evaluate(100.06)).to include(passed: true)
    expect(evaluate(99.94)).to include(passed: true)
    history.each { |b| b.high_price = 100.2; b.low_price = 99.8 }
    expect(evaluate(100.06)).to include(passed: false, threshold_percent: 0.2)
    expect(evaluate(100.25)).to include(passed: true)
  end
  it 'does not guess missing prices or use the current bar in its baseline' do
    history.first.open_price = nil
    expect(evaluate(101)).to include(passed: false, reason: 'missing_prices')
    expect(evaluate(101, history: [])).to include(passed: false)
  end
  it 'keeps the quality measurement when disabled and validates editable settings' do
    instrument.update!(volume_noise_filter: false, volume_min_change_percent: 0.1)
    expect(evaluate(100.06)).to include(enabled: false, passed: false, threshold_percent: 0.1)
    expect(instrument.update(volume_min_change_percent: -1)).to be false
  end
end
