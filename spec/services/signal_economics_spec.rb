require 'rails_helper'

RSpec.describe 'Signal outcome economics and coverage' do
  around { |e| travel_to(Time.zone.local(2026, 10, 16, 12)) { e.run } }
  let(:instrument) { create_instrument }
  def event(**attrs)
    instrument.signals.create!({kind: 'reversal', title: 'Event', event_key: SecureRandom.uuid,
      occurred_at: Time.current, details: { direction: 'up' }}.merge(attrs))
  end
  def rows(**opts)
    DailySignalStatistics.call(date: Date.current, horizon: 15, **opts).index_by { |r| r[:key] }
  end

  it 'calculates cost sensitivity, win/loss sizes and excursions with the short direction reversed' do
    [[1, 'up', 1.5, -0.3], [0.5, 'down', 0.7, -1], [0, 'up', 0, 0]].each do |change, direction, high, low|
      signal = event(details: { direction: direction })
      signal.reaction.update!(results: { '15' => { status: 'measured', candles: 15, change_percent: change,
        high_percent: high, low_percent: low } })
    end
    costs = SignalCosts.new(commission_per_side: '0.01', spread: '0.02', slippage_per_side: '0.005')
    expect(costs.round_trip_percent).to eq(0.05)
    row = rows(costs: costs)['reversal']
    expect(row).to include(directional: 3, positive: 1, negative: 1, flat: 1,
      average_win: 1.0, average_loss: -0.5, net_positive: 1, excursion_measured: 3, full_coverage: 100.0)
    expect(row[:net_mean]).to be_within(0.000001).of((0.95 - 0.55 - 0.05) / 3)
    expect(row[:net_profit_factor]).to be_within(0.000001).of(0.95 / 0.6)
    expect(row[:favorable_mean]).to be_within(0.000001).of(2.5 / 3)
    expect(row[:adverse_mean]).to be_within(0.000001).of(-1.0 / 3)
  end

  it 'separates overdue, pending, unavailable, recoverable and partial windows with legacy reasons' do
    event.reaction.update!(reference_at: 20.minutes.ago, next_check_at: 1.minute.from_now)
    event
    gap = event.reaction
    gap.update!(reference_at: 30.minutes.ago, results: { '15' => { status: 'measured', candles: 14, change_percent: 0.1 } })
    event.reaction.update!(reference_at: 30.minutes.ago, next_check_at: nil,
      results: { '15' => { status: 'unavailable', reason: 'Нет начальной биржевой свечи' } })
    row = rows['reversal']
    expect(row).to include(total: 4, pending: 2, overdue: 1, partial: 1, recovering: 1, full: 0, full_coverage: 0.0,
      quality_reasons: { 'missing_minutes' => 1, 'missing_start' => 1 }, excursion_measured: 0)
  end

  it 'does not count derived stages as new opportunities, including when the source is from yesterday' do
    root = event(kind: 'volume', episode_direction: 'buy', created_at: 1.day.ago)
    event(kind: 'volume_followthrough', details: { source_id: root.id, direction: 'up' })
    today = event
    event(kind: 'reversal_structure', details: { parent_signal_id: today.id, direction: 'up' })
    expect(rows['scenarios']).to include(total: 1, linked_events: 2)
    expect(rows['structure'][:total]).to eq(1)
  end

  it 'rejects negative, nonnumeric and nonfinite costs' do
    %w[-1 abc NaN Infinity 101].each do |value|
      expect { SignalCosts.new(spread: value) }.to raise_error(ArgumentError)
    end
    expect(SignalCosts.new.configured?).to be false
  end
end
