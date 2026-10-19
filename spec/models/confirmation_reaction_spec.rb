require 'rails_helper'

RSpec.describe MarketSignal do
  let(:instrument) { create_instrument }
  around { |example| travel_to(Time.zone.local(2026, 9, 23, 12, 0, 36)) { example.run } }
  let(:signal) { instrument.signals.create!(kind: 'reversal', reversal_status: 'possible', title: 'Откуп', event_key: 'confirm-me', occurred_at: 2.minutes.ago, details: { direction: 'up' }) }

  it 'creates an independent measurement from actual confirmation time, even for a recovered old candle' do
    first = signal.reaction
    travel 4.minutes
    time = Time.current
    ReversalTracker.finish(signal, 'confirmed', 'Recovered confirmation', 3.minutes.ago)
    expect(signal.reload.confirmed_at).to eq(time)
    expect(signal.confirmation_reaction).to have_attributes(phase: 'confirmation', reference_at: time.beginning_of_minute + 1.minute)
    expect(signal.reaction.id).to eq(first.id)
    expect(signal.reaction.reference_at).to eq(Time.zone.local(2026, 9, 23, 12, 1))
    reference = signal.confirmation_reaction.reference_at
    travel 2.minutes
    signal.update!(reversal_status: 'confirmed', title: 'Updated title')
    expect(signal.reactions.count).to eq(2)
    expect(signal.reload.confirmation_reaction.reference_at).to eq(reference)
    expect(signal.confirmed_at).to eq(time)
  end

  it 'does not create a confirmation measurement for cancelled or expired candidates' do
    signal.update!(reversal_status: 'cancelled')
    expect(signal.confirmed_at).to be_nil
    expect(signal.reactions.pluck(:phase)).to eq(['initial'])
  end

  it 'does not guess a timestamp when a legacy confirmed signal is edited' do
    signal.update_columns(reversal_status: 'confirmed')
    signal.reload.update!(title: 'Legacy confirmed')
    expect(signal.reload.confirmed_at).to be_nil
    expect(signal.confirmation_reaction).to be_nil
  end

  it 'deletes both phases with the signal or the instrument' do
    signal.update!(reversal_status: 'confirmed')
    expect { signal.destroy! }.to change(SignalReaction, :count).by(-2)
    other = instrument.signals.create!(kind: 'reversal', reversal_status: 'confirmed', event_key: 'other', title: 'Other', occurred_at: Time.current)
    expect(other.reactions.count).to eq(2)
    expect { instrument.destroy! }.to change(SignalReaction, :count).by(-2)
  end
end
