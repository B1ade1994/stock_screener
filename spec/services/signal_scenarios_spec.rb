require 'rails_helper'

RSpec.describe SignalScenarios do
  let(:instrument) { create_instrument }
  def event(kind: 'volume', instrument: self.instrument, **attrs)
    instrument.signals.create!({kind: kind, title: 'Event', event_key: SecureRandom.uuid, occurred_at: Time.current}.merge(attrs))
  end

  it 'resolves nested experimental stages to their original event without merging nearby unrelated signals' do
    root = event(kind: 'reversal')
    structure = event(kind: 'reversal_structure', research_only: true, details: { parent_signal_id: root.id })
    control = event(kind: 'directional_hint', details: { source_signal_id: structure.id })
    trial = event(kind: 'directional_hint', details: { control_id: control.id })
    unrelated = event(kind: 'reversal')
    resolver = described_class.new([trial, unrelated])
    expect(resolver.representatives.map(&:id)).to contain_exactly(root.id, unrelated.id)
    expect(described_class.timeline(root).map(&:id)).to eq([root, structure, control, trial].map(&:id))
  end

  it 'groups the same daily breakout across dates and leaves a new breakout separate' do
    d = { level_id: 123, breakout_started_at: '2026-10-12T03:00:00+03:00', side: 'resistance' }
    root = event(kind: 'confirmed', details: d)
    retest = event(kind: 'retest', details: d, created_at: 1.day.from_now)
    other = event(kind: 'confirmed', details: d.merge(breakout_started_at: '2026-10-13T03:00:00+03:00'))
    expect(described_class.new([retest, other]).representatives.map(&:id)).to contain_exactly(root.id, other.id)
  end

  it 'keeps broken, cross-instrument and cyclic links separate' do
    root = event
    foreign = event(instrument: create_instrument, details: { source_id: root.id })
    missing = event(details: { source_id: root.id + 1_000_000 })
    first = event
    second = event(details: { source_id: first.id })
    first.update!(details: { source_id: second.id })
    resolver = described_class.new([foreign, missing, first, second])
    expect(resolver.representatives.map(&:id)).to contain_exactly(foreign.id, missing.id, first.id, second.id)
    expect(resolver.unresolved_ids).to contain_exactly(foreign.id, missing.id, first.id, second.id)
  end
end
