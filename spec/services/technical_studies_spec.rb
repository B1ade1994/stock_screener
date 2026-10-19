require 'rails_helper'

RSpec.describe TechnicalStudies do
  let(:instrument) { create_instrument }
  around { |e| travel_to(Time.zone.local(2026, 10, 16, 12)) { e.run } }

  def reversal(direction: 'up')
    instrument.signals.create!(kind: 'reversal', title: 'Source', event_key: SecureRandom.uuid, occurred_at: Time.current,
      reversal_status: 'possible', details: { direction: direction, entry_price: '100',
        extreme: direction == 'up' ? '98.5' : '101.5', volatility: '1',
        rebound_boundary: direction == 'up' ? '100.5' : '99.5', last_checked_at: 1.minute.ago.iso8601 })
  end

  def crossing(side: 'resistance')
    instrument.signals.create!(kind: 'crossing', title: 'Crossing', event_key: SecureRandom.uuid, occurred_at: Time.current,
      details: { side: side, strength_grade: 3, lower: side == 'resistance' ? '99' : '100',
        upper: side == 'resistance' ? '100' : '101', buffer: '0.1', price: side == 'resistance' ? '100.2' : '99.8' })
  end

  def bar(source, offset, low:, high:, close:)
    instrument.reversal_minutes.create!(time: source.occurred_at.beginning_of_minute + offset.minutes,
      open_price: close, close_price: close, low_price: low, high_price: high, volume: 100, data_source: 't_invest')
  end

  def advance(source, bar)
    travel_to bar.time + 96.seconds
    described_class.process(source, now: Time.current)
    source.reload
  end

  it 'requires an independent pullback candle and a later breakout, then starts a fresh silent measurement' do
    source = reversal
    reference = source.reaction.reference_at
    first = bar(source, 0, low: 99.9, high: 101, close: 100.8)
    advance(source, first)
    expect(instrument.signals.count).to eq(1)
    expect(source.details['technical_study']).not_to have_key('pullback_at')
    advance(source, bar(source, 1, low: 100.1, high: 100.9, close: 100.4))
    expect(instrument.signals.count).to eq(1)
    advance(source, bar(source, 2, low: 100.3, high: 101.4, close: 101.2))
    child = instrument.signals.find_by(experiment: described_class::STRUCTURE)
    expect(child).to be_research_only
    expect(child.details).to include('direction' => 'up', 'parent_signal_id' => source.id)
    expect(child.reaction.reference_at).to eq(Time.current.beginning_of_minute + 1.minute)
    expect(source.reversal_status).to eq('possible')
    expect(source.reaction.reference_at).to eq(reference)
    expect(instrument.signals.visible.maximum(:id)).to eq(source.id)
    expect { described_class.process(source) }.not_to change(MarketSignal, :count)
  end

  it 'handles the pullback and subsequent breakdown symmetrically for shorts' do
    source = reversal(direction: 'down')
    advance(source, bar(source, 0, low: 99, high: 100.1, close: 99.2))
    advance(source, bar(source, 1, low: 99.1, high: 99.9, close: 99.6))
    advance(source, bar(source, 2, low: 98.6, high: 99.6, close: 98.8))
    expect(instrument.signals.find_by(experiment: described_class::STRUCTURE).details['direction']).to eq('down')
  end

  it 'invalidates the original extreme before accepting a favorable close in the same candle' do
    source = reversal
    advance(source, bar(source, 0, low: 99.9, high: 101, close: 100.8))
    advance(source, bar(source, 1, low: 100.1, high: 100.9, close: 100.4))
    advance(source, bar(source, 2, low: 98.5, high: 101.4, close: 101.2))
    expect(source.details.dig('technical_study', 'status')).to eq('cancelled')
    expect(instrument.signals.where(experiment: described_class::STRUCTURE)).to be_empty
  end

  it 'waits at gaps and never turns late historical confirmation into a new signal' do
    source = reversal
    first = bar(source, 0, low: 99.9, high: 101, close: 100.8)
    advance(source, first)
    last = bar(source, 2, low: 100.3, high: 101.4, close: 101.2)
    advance(source, last)
    expect(source.details.dig('technical_study', 'checked_at')).to eq(first.time.iso8601)
    bar(source, 1, low: 100.1, high: 100.9, close: 100.4)
    travel_to source.occurred_at + 10.minutes
    described_class.process(source)
    expect(source.reload.details.dig('technical_study', 'reason')).to eq('delayed_confirmation')
    expect(instrument.signals.where(experiment: described_class::STRUCTURE)).to be_empty
  end

  it 'expires missing data even if the instrument no longer receives minutes' do
    source = reversal
    travel 23.minutes
    RefreshTechnicalStudiesJob.perform_now
    expect(source.reload.details.dig('technical_study', 'status')).to eq('expired')
  end

  it 'does not replay a pullback or return that closed before a delayed source was registered' do
    source = instrument.signals.create!(kind: 'reversal', title: 'Delayed', event_key: 'delayed', occurred_at: 3.minutes.ago,
      details: { direction: 'up', entry_price: '100', extreme: '98.5', volatility: '1',
        rebound_boundary: '100.5', last_checked_at: 4.minutes.ago.iso8601 })
    expect(source.details.dig('technical_study', 'checked_at')).to eq(1.minute.ago.iso8601)
    delayed_cross = instrument.signals.create!(kind: 'crossing', title: 'Delayed crossing', event_key: 'delayed-cross', occurred_at: 1.minute.ago,
      details: { side: 'resistance', strength_grade: 3, lower: '99', upper: '100', buffer: '0.1', price: '100.2' })
    expect(delayed_cross.details.dig('technical_study', 'checked_at')).to eq(1.minute.ago.iso8601)
  end

  it 'requires a return inside the strong zone followed by a different candle of reverse continuation' do
    source = crossing
    advance(source, bar(source, 0, low: 99.6, high: 100.4, close: 99.8))
    expect(instrument.signals.where(kind: 'false_breakout')).to be_empty
    advance(source, bar(source, 1, low: 99.2, high: 100.2, close: 99.4))
    child = instrument.signals.find_by(kind: 'false_breakout')
    expect(child).to be_research_only
    expect(child.details).to include('direction' => 'down', 'parent_signal_id' => source.id)
    expect(child.details['invalidation'].to_d).to eq(100.5)
    expect(SignalScenarios.new([child]).representatives.map(&:id)).to eq([source.id])
  end

  it 'mirrors a failed support breakdown into a reversal upward' do
    source = crossing(side: 'support')
    advance(source, bar(source, 0, low: 99.6, high: 100.4, close: 100.2))
    advance(source, bar(source, 1, low: 99.8, high: 100.8, close: 100.6))
    child = instrument.signals.find_by(kind: 'false_breakout')
    expect(child.details['direction']).to eq('up')
    expect(child.details['invalidation'].to_d).to eq(99.5)
  end

  it 'gives invalidation precedence when the outer extreme and confirmation occur in one minute' do
    source = crossing
    advance(source, bar(source, 0, low: 99.6, high: 100.4, close: 99.8))
    advance(source, bar(source, 1, low: 99, high: 100.5, close: 99.2))
    expect(source.details.dig('technical_study', 'status')).to eq('cancelled')
    expect(instrument.signals.where(kind: 'false_breakout')).to be_empty
  end
end
