require 'rails_helper'
require_relative '../support/reversal_helpers'

RSpec.describe DirectionalHints do
  include ReversalHelpers
  let(:instrument) { create_instrument(reversal_enabled: true, breakout_enabled: true) }
  around { |example| travel_to(Time.zone.local(2026, 9, 29, 14, 0, 36)) { example.run } }

  def bar(at: Time.current.beginning_of_minute - 2.minutes, close: 100, low: 99.9, high: 100.1)
    instrument.reversal_minutes.create!(time: at, open_price: close, close_price: close,
      low_price: low, high_price: high, volume: 100, data_source: 't_invest')
  end

  def candidate(direction: 'up')
    b = bar
    described_class.create(instrument, b,
      { direction: direction, extreme: direction == 'up' ? 98 : 102, volatility: 1, rebound_boundary: 100 },
      key: SecureRandom.uuid, basis: 'Test', now: Time.current)
  end

  def follow(hint, close: 100.4, low: 100.2, high: 100.5)
    at = Time.iso8601(hint.details.fetch('last_checked_at')) + 1.minute
    b = bar(at: at, close: close, low: low, high: high)
    travel_to at + 96.seconds
    described_class.advance_history(hint, at, now: Time.current)
    b
  end

  it 'has retired new production candidates even with a fresh eligible source' do
    b = bar
    instrument.signals.create!(kind: 'reversal', reversal_status: 'possible', title: 'Fresh', event_key: 'retired', occurred_at: b.time + 60,
      details: { direction: 'up', extreme: 98, volatility: 1, rebound_boundary: 100 })
    expect { described_class.call(instrument) }.not_to change { instrument.signals.where(kind: described_class::KIND).count }
    expect { RefreshDirectionalHintsJob.perform_now }.not_to change { instrument.signals.where(kind: described_class::KIND).count }
  end

  it 'registers a fresh source once, silently, with frozen decision prices and its own reaction' do
    b = bar
    source = instrument.signals.create!(kind: 'reversal', reversal_status: 'possible', title: 'Откуп', event_key: 'source', occurred_at: b.time + 60,
      details: { direction: 'up', extreme: 98, volatility: 1, rebound_boundary: 100 })
    described_class.call(instrument, collect: true)
    2.times { described_class.call(instrument, collect: true) }
    hint = instrument.signals.where(kind: described_class::KIND, experiment: described_class::EXPERIMENT).sole
    expect(hint).to have_attributes(research_only: true, experiment: 'directional_v1', reversal_status: 'possible')
    expect(hint.details).to include('decision_price' => '100.0', 'source_signal_id' => source.id, 'horizons' => [15, 60])
    expect(hint.details['invalidation'].to_d).to eq(97.9)
    expect(hint.reaction.reference_at).to eq(Time.current.beginning_of_minute + 1.minute)
    expect(MarketSignal.visible.maximum(:id)).to eq(source.id)
  end

  it 'creates no hints from stale or disabled data and never rewrites old sources' do
    b = bar
    instrument.signals.create!(kind: 'reversal', reversal_status: 'possible', title: 'Old', event_key: 'old', occurred_at: b.time + 60,
      details: { direction: 'up', extreme: 98, volatility: 1, rebound_boundary: 100 })
    instrument.update!(reversal_enabled: false)
    described_class.call(instrument, collect: true)
    instrument.update!(reversal_enabled: true)
    travel 6.minutes
    described_class.call(instrument, collect: true)
    expect(instrument.signals.where(kind: described_class::KIND, experiment: described_class::EXPERIMENT)).to be_empty
  end

  it 'confirms only after two consecutive closes and preserves both initial conditions and reference' do
    hint = candidate
    frozen = hint.details.slice('decision_at', 'decision_price', 'invalidation', 'confirmation_price')
    reference = hint.reaction.reference_at
    follow(hint)
    expect(hint.reversal_status).to eq('possible')
    follow(hint, close: 100, low: 99.9, high: 100.1)
    follow(hint)
    expect(hint.reversal_status).to eq('possible')
    follow(hint)
    expect(hint.reload.reversal_status).to eq('confirmed')
    expect(hint.confirmed_at).to eq(Time.current)
    expect(hint.confirmation_reaction.reference_at).to eq(Time.current.beginning_of_minute + 1.minute)
    expect(hint.reaction.reference_at).to eq(reference)
    expect(hint.details.slice(*frozen.keys)).to eq(frozen)
  end

  it 'cancels before confirming when both boundaries are crossed within one minute' do
    hint = candidate
    follow(hint)
    follow(hint, low: 97.8)
    expect(hint.reload.reversal_status).to eq('cancelled')
    expect(hint.confirmed_at).to be_nil
    expect(hint.details['monitoring']).to be(false)
  end

  it 'handles shorts symmetrically and keeps measuring after a later cancellation' do
    hint = candidate(direction: 'down')
    2.times { follow(hint, close: 99.6, low: 99.5, high: 99.8) }
    expect(hint.reload.reversal_status).to eq('confirmed')
    confirmed_at = hint.confirmed_at
    follow(hint, close: 100, low: 99.5, high: 102.2)
    expect(hint.reload.reversal_status).to eq('cancelled')
    expect(hint.confirmed_at).to eq(confirmed_at)
    expect(hint.reactions.count).to eq(2)
    expect(hint.reactions.all? { |r| r.next_check_at.present? }).to be(true)
    rows = DailySignalStatistics.call(date: Date.current, horizon: 15).index_by { |r| r[:key] }
    expect(rows['directional_hint'][:total]).to eq(1)
    expect(rows['hint_confirmation'][:total]).to eq(1)
    expect(rows['confirmation'][:total]).to eq(0)
    expect(rows['levels'][:total]).to eq(0)
  end

  it 'waits for missing minutes and expires without inventing a confirmation' do
    hint = candidate
    at = Time.iso8601(hint.details['last_checked_at']) + 2.minutes
    bar(at: at, close: 100.4, low: 100.2, high: 100.5)
    described_class.advance_history(hint, at, now: Time.current)
    expect(hint.details['confirmation_closes']).to eq(0)
    travel 13.minutes
    instrument.update!(enabled: false)
    RefreshDirectionalHintsJob.perform_now
    expect(hint.reload.reversal_status).to eq('expired')
    expect(hint.confirmed_at).to be_nil
  end

  it 'rejects historical confirmations received after the delivery grace' do
    hint = candidate
    previous = Time.iso8601(hint.details['last_checked_at'])
    2.times { |i| bar(at: previous + (i + 1).minutes, close: 100.4, low: 100.2, high: 100.5) }
    travel 13.minutes
    described_class.advance_history(hint, previous + 2.minutes, now: Time.current)
    expect(hint.reload.reversal_status).to eq('expired')
    expect(hint.confirmation_reaction).to be_nil
  end

  it 'takes confirmation reference from actual receipt time after a short recovery delay' do
    hint = candidate
    previous = Time.iso8601(hint.details['last_checked_at'])
    2.times { |i| bar(at: previous + (i + 1).minutes, close: 100.4, low: 100.2, high: 100.5) }
    travel 5.minutes
    described_class.advance_history(hint, previous + 2.minutes, now: Time.current)
    expect(hint.reload.confirmed_at).to eq(Time.current)
    expect(hint.confirmation_reaction.reference_at).to eq(Time.current.beginning_of_minute + 1.minute)
  end

  it 'requires a strong level and a closed minute outside the zone' do
    b = bar(close: 104, low: 103.8, high: 104.2)
    source = instrument.signals.create!(kind: 'crossing', title: 'Crossing', event_key: 'level', occurred_at: b.time,
      details: { side: 'resistance', strength_grade: 2, lower: 99, upper: 100, buffer: 1 })
    described_class.call(instrument, collect: true)
    expect(instrument.signals.where(kind: described_class::KIND, experiment: described_class::EXPERIMENT)).to be_empty
    source.update!(details: source.details.merge('strength_grade' => 3))
    described_class.call(instrument, collect: true)
    hint = instrument.signals.where(kind: described_class::KIND, experiment: described_class::EXPERIMENT).sole
    expect(hint.details['invalidation'].to_d).to eq(100)
    expect(hint.details['direction']).to eq('up')
  end
end
