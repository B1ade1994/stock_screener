require 'rails_helper'
RSpec.describe 'Filtered volume episodes' do
  let(:instrument) { create_instrument }
  around { |e| travel_to(Time.zone.local(2026,9,25,12,0,36)) { e.run } }
  def record(offset, passed:, enabled: true)
    bar = MarketMinute.new(time: Time.zone.local(2026,9,25,11,59) + offset.minutes, session: 'test')
    details = { volume: 400, baseline: 100, ratio: 4, buy: 350, sell: 50, unknown: 0,
      open_price: '100', close_price: passed ? '101' : '100', quality: {version: 1, enabled: enabled, passed: passed, threshold_percent: 0.05} }
    VolumeEpisode.record(instrument: instrument, bar: bar, details: details)
  end
  it 'stores rejected bursts with outcomes and starts a fresh visible reference for a later accepted burst' do
    rejected = record(0, passed: false)
    expect(rejected).to be_research_only
    first_reference = rejected.reaction.reference_at
    travel 3.minutes
    accepted = record(3, passed: true)
    expect(accepted).not_to be_research_only
    expect(accepted.reaction.reference_at).to be > first_reference
    expect(record(4, passed: true).id).to eq(accepted.id)
    expect(record(5, passed: false).id).to eq(rejected.id)
    expect(rejected.reload.details['decision']).to include('passed' => false)
    expect(accepted.reload.details['decision']).to include('passed' => true)
  end
  it 'does not reclassify or duplicate a delivered minute after settings change, including a later burst' do
    first = record(0, passed: false)
    record(2, passed: false)
    expect { record(2, passed: true, enabled: false) }.not_to change(MarketSignal, :count)
    expect(first.reload.details['burst_count']).to eq(2)
    expect(first).to be_research_only
  end
  it 'allows all anomalies when the filter is disabled' do
    expect(record(0, passed: false, enabled: false)).not_to be_research_only
  end
  it 'applies quality from actual preceding complete candles through the evaluator' do
    at = Time.current.beginning_of_minute - 1.minute
    20.times { |i| instrument.market_minutes.create!(time: at - (20-i).minutes, session: 'test', complete: true, buy: 80, sell: 20, open_price: 100, close_price: 100, high_price: 100.04, low_price: 99.96) }
    bar = instrument.market_minutes.create!(time: at, session: 'test', complete: true, buy: 350, sell: 50, open_price: 100, close_price: 100.02, high_price: 100.04, low_price: 100)
    SignalEvaluator.volume(instrument, bar)
    expect(instrument.signals.where(kind: "volume").sole).to be_research_only
    expect(instrument.signals.where(kind: "volume").sole.details['decision']).to include('reason'=>'small_move', 'threshold_percent'=>0.05)
  end
end
