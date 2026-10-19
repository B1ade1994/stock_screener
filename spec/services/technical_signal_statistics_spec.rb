require 'rails_helper'

RSpec.describe TechnicalSignalStatistics do
  around { |e| travel_to(Time.zone.local(2026, 10, 16, 12)) { e.run } }
  let(:instrument) { create_instrument }

  def event(location: 'near_support', alignment: 'countertrend', **attrs)
    signal = instrument.signals.create!({kind: 'volume', title: 'Volume', event_key: SecureRandom.uuid,
      occurred_at: Time.current, episode_direction: 'sell'}.merge(attrs))
    signal.update!(details: signal.details.merge('technical_context' => { 'version' => 1, 'direction' => 'up',
      'location' => location, 'alignment' => alignment, 'candle' => { 'shape' => 'upper_wick' } }))
    signal
  end

  def rows(**opts)
    described_class.call(date: Date.current, horizon: 30, **opts)[:rows]
  end

  it 'uses frozen first-price direction rather than flow and reports overlapping subgroups explicitly' do
    source = event
    source.reaction.update!(results: { '30' => { status: 'measured', candles: 30, change_percent: 0.2 } })
    result = rows
    expect(result.find { |r| r[:cohort] == 'near_countertrend' }).to include(total: 1, directional: 1, positive: 1, mean: 0.2)
    expect(result.find { |r| r[:cohort] == 'wick' }[:total]).to eq(1)
    expect(result.find { |r| r[:cohort] == 'all' }[:family_selected]).to eq(1)
    expect(result.none? { |r| r[:cohort] == 'away' }).to be true
  end

  it 'selects non-overlapping parent events before splitting by favorable features or known outcomes' do
    event(location: 'away', alignment: 'with_trend') # No future outcome yet.
    travel 2.minutes
    source = event
    source.reaction.update!(results: { '30' => { status: 'measured', candles: 30, change_percent: 1.0 } })
    result = rows
    expect(result.find { |r| r[:cohort] == 'all' }).to include(total: 1, pending: 1, measured: 0, family_total: 2)
    expect(result.none? { |r| r[:cohort] == 'near' }).to be true
    expect(rows(non_overlapping: false).find { |r| r[:cohort] == 'near' }[:measured]).to eq(1)
  end

  it 'keeps missing locations distinct from distant zones and excludes unlabeled legacy events' do
    event(location: 'unknown', alignment: 'unknown')
    instrument.signals.create!(kind: 'volume', title: 'Legacy', event_key: 'legacy', occurred_at: Time.current)
    report = described_class.call(date: Date.current, horizon: 30)
    expect(report).to include(labeled: 1, unlabeled: 1, primary_horizon: 30)
    expect(report[:rows].find { |r| r[:cohort] == 'unknown_location' }[:total]).to eq(1)
    expect(report[:rows].none? { |r| r[:cohort] == 'away' || r[:cohort] == 'with_trend' }).to be true
  end

  it 'uses confirmation-day measurements for reversals and keeps control and new structures separate' do
    source = event(kind: 'reversal', experiment: nil, reversal_status: 'possible')
    source.update!(details: source.details.merge('direction' => 'up'))
    travel 2.minutes
    source.update!(reversal_status: 'confirmed')
    source.confirmation_reaction.update!(results: { '30' => { status: 'measured', candles: 30, change_percent: -0.1 } })
    event(kind: 'reversal_structure', experiment: 'structure_v1', research_only: true)
    event(kind: 'reversal_structure', experiment: TechnicalStudies::STRUCTURE, research_only: true)
    report = rows(non_overlapping: false)
    expect(report.find { |r| r[:family] == 'reversal_confirmation' && r[:cohort] == 'all' }).to include(negative: 1, mean: -0.1)
    expect(report.select { |r| r[:cohort] == 'all' }.map { |r| r[:family] }).to contain_exactly('reversal_confirmation', 'structure_v1', 'pullback')
  end
end
