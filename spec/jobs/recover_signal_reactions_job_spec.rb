require 'rails_helper'

RSpec.describe RecoverSignalReactionsJob, type: :job do
  around { |e| travel_to(Time.zone.local(2026, 10, 16, 12)) { e.run } }

  def reaction
    create_instrument.signals.create!(kind: 'volume', title: 'Event', event_key: SecureRandom.uuid, occurred_at: Time.current).reaction
  end

  it 'reopens recent legacy gaps without reopening complete or old observations' do
    gap = reaction
    full = reaction
    old = reaction
    gap.update!(reference_at: 2.hours.ago, next_check_at: nil,
      results: SignalReaction::HORIZONS.to_h { |h| [h.to_s, { status: 'measured', candles: h - 1 }] })
    full.update!(reference_at: 2.hours.ago, next_check_at: nil,
      results: SignalReaction::HORIZONS.to_h { |h| [h.to_s, { status: 'measured', candles: h }] })
    old.update!(reference_at: 26.hours.ago, next_check_at: nil, results: { '15' => { status: 'unavailable' } })
    described_class.perform_now
    expect(gap.reload.next_check_at).to eq(5.minutes.from_now)
    expect(full.reload.next_check_at).to be_nil
    expect(old.reload.next_check_at).to be_nil
  end
end
