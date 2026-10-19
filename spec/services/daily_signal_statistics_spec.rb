require 'rails_helper'

RSpec.describe DailySignalStatistics do
  let(:instrument) { create_instrument }
  around { |example| travel_to(Time.zone.local(2026, 9, 23, 12, 0, 36)) { example.run } }

  def event(kind: 'volume', side: 'buy', **attrs)
    instrument.signals.create!({kind: kind, title: 'Test', event_key: SecureRandom.uuid, occurred_at: Time.current,
      episode_direction: kind == 'volume' ? side : nil, details: { direction: side } }.merge(attrs))
  end

  def measure(reaction, change, count: 15, baseline: 'down')
    reaction.update!(results: { '15' => { status: 'measured', change_percent: change, candles: count } },
      baseline: { status: 'measured', direction: baseline })
  end

  def rows(full: true, date: Date.current)
    described_class.call(date: date, horizon: 15, full_only: full).index_by { |row| row[:key] }
  end

  it 'separates incomplete, unavailable, pending and undirected observations without treating them as zero' do
    measure(event.reaction, 1)
    measure(event(side: 'sell').reaction, -2, baseline: 'down')
    measure(event.reaction, 0)
    measure(event(side: 'mixed').reaction, 4)
    measure(event.reaction, 5, count: 14)
    event
    event.reaction.update!(results: { '15' => { status: 'unavailable' } })
    row = rows['volume']
    expect(row).to include(total: 7, measured: 5, used: 4, partial: 1, excluded: 1, pending: 1, unavailable: 1,
      directional: 3, positive: 2, negative: 0, flat: 1, undirected: 1, mean: 1.0, median: 1.0, paired: 3, signal_matches: 2, baseline_matches: 1)
    expect(rows(full: false)['volume']).to include(used: 5, excluded: 0, partial: 1, directional: 4)
  end

  it 'excludes missing and flat control trends from paired comparison only' do
    first = event; measure(first.reaction, 1, baseline: 'flat')
    second = event; measure(second.reaction, -1); second.reaction.update!(baseline: {})
    expect(rows['volume']).to include(directional: 2, paired: 0, positive: 1, negative: 1)
  end

  it 'keeps all candidates and measures confirmed signals from their own reference, not future status selection' do
    candidate = event(kind: 'reversal', side: 'up', reversal_status: 'possible')
    measure(candidate.reaction, 2)
    travel 3.minutes
    candidate.update!(reversal_status: 'confirmed')
    measure(candidate.reload.confirmation_reaction, -1)
    cancelled = event(kind: 'reversal', side: 'up', reversal_status: 'cancelled')
    measure(cancelled.reaction, -2)
    expect(rows['reversal']).to include(total: 2, positive: 1, negative: 1, mean: 0.0)
    expect(rows['confirmation']).to include(total: 1, negative: 1, mean: -1.0)
  end

  it 'assigns confirmation to its Moscow day across midnight and leaves legacy confirmations untracked' do
    travel_to Time.zone.local(2026, 9, 23, 23, 59, 40)
    candidate = event(kind: 'reversal', side: 'up', reversal_status: 'possible')
    travel 1.minute
    candidate.update!(reversal_status: 'confirmed')
    expect(rows(date: Date.new(2026, 9, 23))['reversal'][:total]).to eq(1)
    expect(rows(date: Date.new(2026, 9, 23))['confirmation'][:total]).to eq(0)
    expect(rows(date: Date.new(2026, 9, 24))['confirmation']).to include(total: 1, pending: 1)
    legacy = event(kind: 'reversal', side: 'up', reversal_status: 'possible')
    legacy.update_columns(reversal_status: 'confirmed')
    expect(rows['confirmation']).to include(total: 2, untracked: 1)
  end

  it 'does not assign an intraday prediction to historical level context' do
    signal = event(kind: 'confirmed')
    measure(signal.reaction, 1)
    expect(rows['levels']).to include(used: 1, undirected: 1, directional: 0, mean: nil)
  end
end
