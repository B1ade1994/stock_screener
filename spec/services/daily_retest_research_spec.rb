require 'rails_helper'

RSpec.describe DailyRetestResearch do
  let(:instrument) { create_instrument(kind: 'futures', ticker: 'IMOEXF', class_code: 'SPBFUT', reversal_enabled: false) }
  let(:zone) { DailyRetestLevels::Zone.new(side: 'resistance', timeframe: 'day', lower_price: 98, upper_price: 100, touches: 3, assessment: { 'score' => 7, 'as_of' => '2026-10-01' }) }
  around { |example| travel_to(Time.zone.local(2026, 10, 7, 12)) { example.run } }
  before do
    day = instance_double(DailyRetestLevels, strong: [zone], push: nil)
    week = instance_double(DailyRetestLevels, strong: [], push: nil)
    allow(DailyRetestLevels).to receive(:new).with(instrument.id, 'day').and_return(day)
    allow(DailyRetestLevels).to receive(:new).with(instrument.id, 'week').and_return(week)
    allow(MarketIndicators).to receive(:atr) { |bars| Array.new(bars.size, 2) }
  end
  def candle(day, close:, low: close - 1, high: close + 1, source: 't_invest')
    instrument.candles.create!(timeframe: 'day', time: Time.utc(2026, 10, day), data_source: source, open: close, high: high, low: low, close: close, volume: 100)
  end
  def activate
    candle(6, close: 99)
    described_class.call(instrument)
  end
  def breakout
    candle(7, close: 102, low: 99)
    travel_to Time.zone.local(2026, 10, 8, 12)
    described_class.call(instrument)
  end
  def confirm
    activate; breakout
    candle(8, close: 103, low: 100)
    travel_to Time.zone.local(2026, 10, 9, 12)
    described_class.call(instrument)
    instrument.signals.where(kind: described_class::KIND).sole
  end

  it 'starts forward only and emits one silent daily confirmation independently of reversal scanning' do
    signal = confirm
    expect(signal).to have_attributes(research_only: true, confirmed_at: Time.current, reversal_status: 'confirmed')
    expect(signal.details['zones'].sole).to include('score' => 7, 'bars' => 1)
    expect(signal.details['stop'].to_d).to eq(97.8)
    expect(signal.reactions).to be_empty
    expect { described_class.call(instrument) }.not_to change(MarketSignal, :count)
    expect(instrument.reload.daily_retest_state['cooldown']).to eq(10)
  end
  it 'leaves shares and their scanners untouched' do
    share = create_instrument
    expect { described_class.call(share) }.not_to change { share.reload.attributes }
    expect(described_class.eligible?(share)).to be(false)
  end
  it 'admits only futures and the supported metals' do
    gold = create_instrument(kind: 'currency', ticker: 'GLDRUB_TOM', class_code: 'CETS')
    silver = create_instrument(kind: 'currency', ticker: 'SLVRUB_TOM', class_code: 'CETS')
    expect([instrument, gold, silver].map { |i| described_class.eligible?(i) }).to eq([true, true, true])
  end
  it 'ignores current-day and proxy candles' do
    candle(6, close: 99)
    candle(7, close: 102)
    described_class.call(instrument)
    expect(Time.iso8601(instrument.daily_retest_state['cursor'])).to eq(Time.utc(2026, 10, 6))
    instrument.candles.find_by(time: Time.utc(2026, 10, 7)).destroy!
    candle(7, close: 102, source: 'yahoo_spy')
    travel_to Time.zone.local(2026, 10, 8, 12)
    described_class.call(instrument)
    expect(instrument.reload.daily_retest_state['pending']).to be_empty
  end
  it 'does not turn a first historical import or delayed pre-activation candles into new ideas' do
    candle(4, close: 99)
    described_class.call(instrument)
    candle(5, close: 102); candle(6, close: 103, low: 100)
    expect { described_class.call(instrument) }.not_to change(MarketSignal, :count)
    expect(instrument.reload.daily_retest_state['pending']).to be_empty
  end
  it 'cancels pending setups when disabled and establishes a fresh baseline on re-enable' do
    activate; breakout
    expect(instrument.daily_retest_state['pending'].size).to eq(1)
    instrument.update!(breakout_enabled: false)
    described_class.call(instrument)
    expect(instrument.daily_retest_state['pending']).to be_empty
    candle(8, close: 103, low: 100)
    travel_to Time.zone.local(2026, 10, 9, 12)
    instrument.update!(breakout_enabled: true)
    expect { described_class.call(instrument) }.not_to change(MarketSignal, :count)
  end
  it 'rejects a historical confirmation recovered together with a newer day' do
    activate; breakout
    candle(8, close: 103, low: 100); candle(9, close: 104, low: 102)
    travel_to Time.zone.local(2026, 10, 10, 12)
    expect { described_class.call(instrument) }.not_to change(MarketSignal, :count)
    expect(instrument.reload.daily_retest_state['late_count']).to eq(1)
  end
  it 'excludes daily research from minute statistics and never generates legacy candidates by default' do
    signal = confirm
    expect(DailySignalStatistics.call(date: Date.current, horizon: 5).sum { |r| r[:total] }).to eq(0)
    expect(DirectionalHints).not_to receive(:create)
    DirectionalHints.call(instrument)
    RefreshDirectionalHintsJob.perform_now
    expect(signal.reload.kind).to eq('daily_retest')
  end

  it 'does not release weekly evidence before the end of its week' do
    activate
    instrument.candles.create!(timeframe: 'week', time: Time.utc(2026, 10, 5), open: 99, close: 99, low: 98, high: 100, volume: 100)
    week = instance_double(DailyRetestLevels, strong: [], push: nil)
    allow(DailyRetestLevels).to receive(:new).with(instrument.id, 'week').and_return(week)
    expect(week).not_to receive(:push)
    breakout
  end

  it 'suppresses the next ten completed candles before considering another signal' do
    s = { 'direction' => 'up', 'lower' => '98', 'upper' => '100', 'buffer' => '0.2', 'bars' => 0, 'status' => 'possible' }
    state = { 'pending' => [s], 'cooldown' => 10 }
    bar = Candle.new(time: 1.day.ago, open: 102, close: 103, low: 100, high: 104)
    expect do
      described_class.process(instrument, state, bar, previous: bar, atr: 2, strong: [], latest: true, now: Time.current)
    end.not_to change(MarketSignal, :count)
    expect(state['cooldown']).to eq(9)
  end
end
