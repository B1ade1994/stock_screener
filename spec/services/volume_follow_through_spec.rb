require 'rails_helper'
RSpec.describe VolumeFollowThrough do
  let(:instrument) { create_instrument }
  around { |e| travel_to(Time.zone.local(2026,10,7,12,0,36)) { e.run } }
  def register(opening = '100', closing = '100.2', atr = 0.1)
    episode = instrument.signals.create!(kind: 'volume', event_key: SecureRandom.uuid, title: 'Volume', occurred_at: Time.current,
      details: { bursts: [{open_price: opening, close_price: closing, ratio: 4, quality: {atr_percent: atr, threshold_percent: 0.05}}] })
    described_class.register(episode)
  end
  def bars(trial, closes)
    reference = Time.iso8601(trial.details['reference_at'])
    closes.each_with_index do |close,i|
      instrument.reversal_minutes.create!(time: reference + i.minutes, open_price: 100, close_price: close,
        high_price: 101, low_price: 99, volume: 100, data_source: 'stream')
    end
    reference
  end
  it 'rejects small moves and unavailable baselines without affecting source visibility' do
    expect(register('100','100.1').reversal_status).to eq('rejected')
    expect(register('100','101',nil).details['reason']).to eq('missing_prices')
    expect(instrument.signals.where(kind: 'volume').visible.count).to eq(2)
  end
  it 'confirms only closed following minutes and measures from actual confirmation, idempotently' do
    trial = register
    reference = bars(trial, [100.15,100.18])
    travel_to(reference + 2.minutes + 34.seconds)
    described_class.process(instrument)
    expect(trial.reload.reversal_status).to eq('possible')
    travel 2.seconds
    described_class.process(instrument)
    expect(trial.reload.reversal_status).to eq('confirmed')
    expect(trial.confirmed_at).to eq(Time.current)
    expect(trial.confirmation_reaction.reference_at).to eq(Time.current.beginning_of_minute + 1.minute)
    expect { described_class.process(instrument) }.not_to change(SignalReaction, :count)
    rows = DailySignalStatistics.call(date: Date.current, horizon: 5)
    expect(rows.find { |r| r[:key] == 'volume_trial_confirmation' }[:total]).to eq(1)
  end
  it 'uses price direction symmetrically for a falling candle' do
    trial = register('100','99.8')
    reference = bars(trial, [99.85,99.82])
    travel_to(reference + 3.minutes)
    described_class.process(instrument)
    expect(trial.reload.reversal_status).to eq('confirmed')
    expect(DailySignalStatistics.direction(trial)).to eq(-1)
  end
  it 'rejects a return and does not use later candles to rescue it' do
    trial = register
    reference = bars(trial, [100.2,100.12])
    travel_to(reference + 3.minutes)
    described_class.process(instrument)
    expect(trial.reload.details['reason']).to eq('returned')
    expect(trial.confirmation_reaction).to be_nil
  end
  it 'expires missing minutes instead of substituting later prices' do
    trial = register
    travel 8.minutes
    described_class.expire
    expect(trial.reload.reversal_status).to eq('expired')
    expect(trial.confirmation_reaction).to be_nil
  end
end
