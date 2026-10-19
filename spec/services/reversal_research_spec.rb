require 'rails_helper'
RSpec.describe ReversalResearch do
  let(:instrument) { create_instrument }
  around { |e| travel_to(Time.zone.local(2026,9,25,12)) { e.run } }
  def candidate(direction='up')
    instrument.signals.create!(kind: 'reversal', reversal_status: 'possible', title: 'Candidate', event_key: SecureRandom.uuid, occurred_at: Time.current,
      details: { direction: direction, volatility: 1, extreme: direction=='up' ? 98 : 102, rebound_boundary: 100, last_checked_at: 1.minute.ago.iso8601, structure_checked_at: 1.minute.ago.iso8601 })
  end
  def bar(offset, low:, high:, close:)
    ReversalMinute.new(time: Time.current + offset.minutes, open_price: close, close_price: close, low_price: low, high_price: high, volume: 100, data_source: 't_invest')
  end
  it 'requires a breakout followed by a later retest, with its own actual notification reference' do
    signal = candidate
    described_class.advance(signal,bar(0,low:99.9,high:100.5,close:100.4))
    expect(instrument.signals.count).to eq(1)
    travel 10.minutes # delayed recovery must not backdate the measurement
    described_class.advance(signal,bar(-9,low:100.1,high:100.5,close:100.4))
    trial = instrument.signals.find_by(kind:'reversal_structure')
    expect(trial).to be_research_only
    expect(trial.reaction.reference_at).to eq(Time.current.beginning_of_minute + 1.minute)
    expect(signal.reload.details['structure_status']).to eq('confirmed')
    expect(signal.reversal_status).to eq('possible')
  end
  it 'does not use a new extreme as a successful retest' do
    signal = candidate
    described_class.advance(signal,bar(0,low:100.3,high:100.5,close:100.4))
    described_class.advance(signal,bar(1,low:97,high:100.5,close:100.4))
    expect(signal.reload.details['structure_status']).to eq('cancelled')
    expect(instrument.signals.where(kind:'reversal_structure')).to be_empty
  end
  it 'handles the downward rule symmetrically' do
    signal=candidate('down')
    described_class.advance(signal,bar(0,low:99.5,high:100.1,close:99.6))
    described_class.advance(signal,bar(1,low:99.5,high:99.9,close:99.6))
    expect(instrument.signals.find_by(kind:'reversal_structure').details['direction']).to eq('down')
  end
  it 'waits for missing minutes and expires after the deadline when data stops' do
    signal=candidate
    missing = bar(1,low:100.1,high:100.5,close:100.4);missing.instrument=instrument;missing.save!
    described_class.process(instrument,missing.time)
    expect(signal.reload.details['structure_broken_at']).to be_nil
    travel 23.minutes
    described_class.expire
    expect(signal.reload.details['structure_status']).to eq('expired')
  end
end
