require 'rails_helper'
require_relative '../support/reversal_helpers'

RSpec.describe HistoricalStrategyReplay do
  include ReversalHelpers
  let(:instrument) { create_instrument(kind: 'futures', ticker: 'BTCUSDperpA') }
  around { |example| travel_to(Time.zone.local(2026, 10, 16, 12)) { example.run } }

  def canonical(bars)
    bars.map { |b| ReversalMinute.new(time: b.time, open_price: b.open_price, close_price: b.close_price,
      low_price: b.low_price, high_price: b.high_price, volume: b.volume, data_source: 't_invest') }
  end
  def replay(bars, through: Time.current)
    described_class.new(instrument: instrument, minutes: bars, days: [], weeks: [], through: through).run
  end

  it 'replays the production reversal rule and its mirrored short without writing market history or live signals' do
    %w[up down].each do |direction|
      bars = canonical(reversal_bars(direction: direction))
      result = nil
      expect { result = replay(bars) }.not_to change(MarketSignal, :count)
      expect(result.events.find { |e| e[:family] == 'reversal' }).to include(direction: direction)
      expect(result.events.find { |e| e[:family] == 'reversal' }[:at]).to eq((bars.last.time + 95.seconds).iso8601)
      expect(instrument.reversal_minutes.count).to eq(0)
    end
  end

  it 'produces identical past decisions when future candles are added or their prices are changed' do
    bars = canonical(reversal_bars)
    cutoff = bars.last.time + 95.seconds
    future = Array.new(20) do |n|
      ReversalMinute.new(time: bars.last.time + (n + 1).minutes, open_price: 100, close_price: 100,
        high_price: 101, low_price: 99, volume: 100, data_source: 't_invest')
    end
    prefix = replay(bars, through: cutoff).events
    full = replay(bars + future, through: cutoff + 20.minutes).events
    expect(full.select { |e| Time.iso8601(e[:at]) <= cutoff }).to eq(prefix)
    future.each { |b| b.open_price = b.close_price = 1000; b.high_price = 1001; b.low_price = 999 }
    changed = replay(bars + future, through: cutoff + 20.minutes).events
    expect(changed.select { |e| Time.iso8601(e[:at]) <= cutoff }).to eq(prefix)
  end

  it 'does not join sparse minutes into an artificial impulse' do
    bars = canonical(reversal_bars)
    bars.delete_at(10)
    expect(replay(bars).events.select { |e| e[:family] == 'reversal' }).to be_empty
  end
end

RSpec.describe HistoricalReplayResults do
  around { |example| travel_to(Time.zone.local(2026, 10, 16, 15)) { example.run } }
  def event(at: Time.zone.local(2026, 10, 16, 12, 0, 35), **attrs)
    { id: 1, family: 'reversal', at: at.iso8601, direction: 'up', daily: false, context: {} }.merge(attrs)
  end
  def minutes
    Array.new(90) do |n|
      ReversalMinute.new(time: Time.zone.local(2026, 10, 16, 12) + n.minutes,
        open_price: n.zero? ? 1 : 100, high_price: 101, low_price: n.zero? ? 1 : 99,
        close_price: 101, volume: 100, data_source: 't_invest')
    end
  end
  def results(events, bars: minutes, days: [])
    described_class.new(events: events, minutes: bars, days: days, through: Time.current).call
  end

  it 'enters after the decision instead of borrowing the profitable open of its already-started candle' do
    e = event
    results([e])
    expect(e[:results][30]).to include(status: 'measured')
    expect(Time.iso8601(e[:results][30][:entry_at])).to eq(Time.zone.local(2026, 10, 16, 12, 1))
    expect(e[:results][30][:change]).to be_within(1e-8).of(1)
    expect(e[:results][30][:entry_price].to_d).to eq(100)
  end
  it 'selects non-overlapping opportunities before learning that the first outcome is missing' do
    bars = minutes
    bars.delete_at(2)
    rows = results([event, event(id: 2, at: Time.zone.local(2026, 10, 16, 12, 5, 35))], bars: bars)
    row = rows.find { |r| r[:family] == 'reversal' && r[:horizon] == 30 }
    expect(row).to include(registered: 2, selected: 1, overlapping: 1, used: 0, statuses: { 'missing_minutes' => 1 })
  end
  it 'separates right-censored outcomes and does not turn gaps into a partial success' do
    e = event(at: 2.minutes.ago)
    results([e])
    expect(e[:results][30][:status]).to eq('censored')
  end
  it 'uses a later daily opening and the worse result when stop and target share one candle' do
    e = event(at: Time.zone.local(2026, 10, 7, 3, 0, 1), family: 'daily_retest_v1', daily: true, stop: '90')
    days = [Candle.new(time: Time.zone.local(2026, 10, 7, 3), open: 1, high: 2, low: 1, close: 2),
      Candle.new(time: Time.zone.local(2026, 10, 8, 3), open: 100, high: 125, low: 85, close: 110)]
    results([e], days: days)
    expect(e[:results][1]).to include(status: 'measured', ambiguous: true, exit_reason: 'ambiguous')
    expect(e[:results][1][:change]).to be_within(1e-8).of(-10)
    expect(e[:results][1][:trade_best]).to be_within(1e-8).of(20)
    expect(e[:results][1][:entry_price].to_d).to eq(100)
  end
end
