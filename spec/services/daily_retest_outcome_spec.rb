require 'rails_helper'

RSpec.describe DailyRetestOutcome do
  let(:instrument) { create_instrument(kind: 'futures') }
  let(:registered) { Time.utc(2026, 10, 7, 12) }
  let(:signal) { instrument.signals.create!(kind: DailyRetestResearch::KIND, experiment: DailyRetestResearch::EXPERIMENT,
    research_only: true, reversal_status: 'confirmed', confirmed_at: registered, occurred_at: registered,
    event_key: SecureRandom.uuid, title: 'Test', details: { direction: 'up', stop: '90', measurement_complete: false, outcomes: {} }) }
  def bar(day, opening: 100, low: 99, high: 101, close: 100)
    Candle.new(time: Time.utc(2026, 10, day), open: opening, low: low, high: high, close: close)
  end
  it 'never uses an opening before registration and records both intraday orders' do
    described_class.refresh(signal, [bar(7, opening: 80, low: 79, high: 81, close: 80), bar(8, low: 85, high: 125, close: 110)])
    expect(Time.iso8601(signal.details['entry_at'])).to eq(Time.utc(2026, 10, 8))
    expect(signal.details['entry_price']).to eq('100.0')
    r = signal.details['outcomes']['1']
    expect(r).to include('ambiguous' => true, 'exit_reason' => 'ambiguous')
    expect(r['trade_low']).to be_within(1e-8).of(-10)
    expect(r['trade_high']).to be_within(1e-8).of(20)
  end
  it 'keeps the original entry and completed marks on retry and waits for a full horizon' do
    days = (8..12).map { |d| bar(d, close: 101) }
    described_class.refresh(signal, days)
    original = signal.details.deep_dup
    described_class.refresh(signal, days)
    expect(signal.details).to eq(original)
    expect(signal.details['outcomes'].keys).to contain_exactly('1', '3', '5')
    expect(signal.details['measurement_complete']).to be(false)
  end
  it 'accounts for gaps through the stop at the worse opening and does not assume favorable target fills' do
    days = [bar(8), bar(9, opening: 85, low: 80, high: 90, close: 85), bar(10)]
    described_class.refresh(signal, days)
    expect(signal.details['outcomes']['3']['trade_low']).to be_within(1e-8).of(-15)
    expect(signal.details['outcomes']['3']['exit_reason']).to eq('stop_gap')
    result = described_class.exit_for([bar(8, opening: 125, low: 121, high: 130, close: 127)], stop: 90, target: 120, up: true)
    expect(result[:worst]).to eq(120)
  end
  it 'marks an invalid opening as missed without creating a result' do
    described_class.refresh(signal, [bar(8, opening: 85, low: 80, high: 89, close: 86)])
    expect(signal.reload.reversal_status).to eq('missed')
    expect(signal.details['outcomes']).to be_empty
  end
  it 'does not measure through missing daily history or malformed candles' do
    described_class.refresh(signal, [bar(8), bar(15), bar(16)])
    expect(signal.details['outcomes']['3']['status']).to eq('unavailable')
  end
  it 'mirrors short target and stop ambiguity' do
    signal.update!(details: signal.details.merge('direction' => 'down', 'stop' => '110'))
    described_class.refresh(signal, [bar(8, low: 75, high: 115, close: 90)])
    r = signal.details['outcomes']['1']
    expect(r['trade_low']).to be_within(1e-8).of(-10)
    expect(r['trade_high']).to be_within(1e-8).of(20)
  end
end
