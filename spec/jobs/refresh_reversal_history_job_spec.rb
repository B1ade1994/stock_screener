require 'rails_helper'

RSpec.describe RefreshReversalHistoryJob, type: :job do
  around { |example| travel_to(Time.zone.local(2026, 9, 22, 14)) { example.run } }

  it 'dispatches separate jobs only for active reversal instruments' do
    active = create_instrument
    create_instrument(uid: SecureRandom.uuid, reversal_enabled: false)
    create_instrument(uid: SecureRandom.uuid, enabled: false)
    expect { described_class.perform_now }.to have_enqueued_job(described_class).with(active.id).exactly(:once)
  end

  it 'records a safe API failure and suppresses immediate duplicate attempts' do
    instrument = create_instrument
    allow(ReversalHistory).to receive(:refresh).and_raise(TInvest::Error, 'Т-Инвестиции: HTTP 429')
    described_class.perform_now(instrument.id)
    expect(instrument.reload.reversal_history_error).to eq('Т-Инвестиции: HTTP 429')
    described_class.perform_now(instrument.id)
    expect(ReversalHistory).to have_received(:refresh).once
    travel 61.seconds
    described_class.perform_now(instrument.id)
    expect(ReversalHistory).to have_received(:refresh).twice
  end

  it 'skips deleted, disabled and expired instruments' do
    instrument = create_instrument(enabled: false)
    expect(ReversalHistory).not_to receive(:refresh)
    described_class.perform_now(instrument.id)
    instrument.update!(enabled: true, expiration_date: Date.yesterday)
    described_class.perform_now(instrument.id)
    instrument.destroy!
    described_class.perform_now(instrument.id)
  end
end
