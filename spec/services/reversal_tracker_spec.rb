require 'rails_helper'
require_relative '../support/reversal_helpers'

RSpec.describe ReversalTracker do
  include ReversalHelpers
  let(:instrument) { create_instrument(volume_enabled: false, reversal_enabled: true) }
  around { |example| travel_to(Time.zone.local(2026, 9, 22, 14)) { example.run } }

  def seed(direction: 'up')
    bars = reversal_bars(direction: direction)
    bars.each { |b| b.instrument = instrument; b.save!; ReversalMinute.record_stream(instrument, b) }
    described_class.process(instrument, bars.last)
    [instrument.signals.find_by(kind: 'reversal'), bars.last]
  end

  def follow(last, offset: 1, close: 99.5, low: 99.3, high: 99.6, session: last.session)
    bar = instrument.market_minutes.create!(time: last.time + offset.minutes, session: session, complete: true,
      open_price: close, close_price: close, high_price: high, low_price: low, trades: 5, buy: 100)
    travel_to bar.time + 96.seconds
    described_class.process(instrument, bar)
    bar
  end

  it 'creates a separate event with reaction tracking even when volume detection is disabled' do
    signal, last = seed
    expect(signal).to have_attributes(kind: 'reversal', reversal_status: 'possible')
    expect(signal.reaction).to be_present
    2.times { described_class.process(instrument, last) }
    expect(instrument.signals.count).to eq(1)
    expect(SignalReaction.count).to eq(1)
  end

  it 'confirms in the same row after two closes, preserving the sound cursor and price reference' do
    signal, last = seed
    reference = signal.reaction.reference_at
    next_bar = follow(last)
    expect(signal.reload.reversal_status).to eq('possible')
    follow(next_bar)
    expect(signal.reload.reversal_status).to eq('confirmed')
    expect(instrument.signals.sole.id).to eq(signal.id)
    expect(signal.reaction.reference_at).to eq(reference)
  end

  it 'requires consecutive confirmation closes' do
    signal, last = seed
    last = follow(last)
    last = follow(last, close: 99.36)
    follow(last)
    expect(signal.reload.reversal_status).to eq('possible')
  end

  it 'cancels on a fresh low even if the same minute closes beyond the confirmation threshold' do
    signal, last = seed
    follow(last, low: 98.8)
    expect(signal.reload.reversal_status).to eq('cancelled')
  end

  it 'confirms the symmetric sell-off' do
    signal, last = seed(direction: 'down')
    last = follow(last, close: 100.5, low: 100.4, high: 100.7)
    follow(last, close: 100.5, low: 100.4, high: 100.7)
    expect(signal.reload.reversal_status).to eq('confirmed')
  end

  it 'cancels a sell-off on a fresh high' do
    signal, last = seed(direction: 'down')
    follow(last, close: 100.5, low: 100.4, high: 101.2)
    expect(signal.reload.reversal_status).to eq('cancelled')
  end

  it 'waits for a missing minute rather than counting nonconsecutive closes' do
    signal, last = seed
    follow(last, offset: 2)
    expect(signal.reload.reversal_status).to eq('possible')
    expect(signal.details['confirmation_closes']).to eq(0)
    travel 15.minutes
    ExpireReversalsJob.perform_now
    expect(signal.reload.reversal_status).to eq('expired')
  end

  it 'honours the global observation switch' do
    instrument.update!(enabled: false)
    signal, = seed
    expect(signal).to be_nil
  end

  it 'preserves confirmation through a session change with complete consecutive minutes' do
    signal, last = seed
    last = follow(last, session: SecureRandom.uuid)
    expect(signal.reload.reversal_status).to eq('possible')
    follow(last)
    expect(signal.reload.reversal_status).to eq('confirmed')
  end

  it 'replays recovered minutes in order and cancels before a later confirming close' do
    signal, last = seed
    follow(last, offset: 2)
    expect(signal.reload.reversal_status).to eq('possible')
    instrument.reversal_minutes.create!(time: last.time + 1.minute, data_source: 't_invest',
      open_price: 99.4, close_price: 99.5, high_price: 99.6, low_price: 98.8, volume: 100)
    described_class.process(instrument, instrument.reversal_minutes.order(:time).last, recheck: true)
    expect(signal.reload.reversal_status).to eq('cancelled')
    expect(signal.details['status_at']).to eq((last.time + 2.minutes).iso8601)
  end

  it 'expires at the deadline without accepting a late confirmation' do
    signal, last = seed
    10.times { last = follow(last, close: 99.36) }
    expect(signal.reload.reversal_status).to eq('expired')
    2.times { last = follow(last) }
    expect(signal.reload.reversal_status).to eq('expired')
  end

  it 'does not detect disabled instruments or stale bars' do
    instrument.update!(reversal_enabled: false)
    signal, last = seed
    expect(signal).to be_nil
    instrument.update!(reversal_enabled: true)
    travel 10.minutes
    described_class.process(instrument, last)
    expect(instrument.signals).to be_empty
  end

  it 'suppresses the same direction for 30 minutes after a completed candidate' do
    signal, last = seed
    follow(last, low: 98.8)
    later = reversal_bars(at: last.time + 28.minutes)
    later.each { |b| b.instrument = instrument; b.save! }
    travel_to later.last.time + 96.seconds
    later.each { |b| ReversalMinute.record_stream(instrument, b) }
    travel_to later.last.time + 96.seconds
    described_class.process(instrument, later.last)
    expect(instrument.signals.count).to eq(1)
  end

  it 'expires pending events when the stream stops, including disabled instruments' do
    signal, = seed
    instrument.update!(reversal_enabled: false)
    travel 15.minutes
    ExpireReversalsJob.perform_now
    expect(signal.reload.reversal_status).to eq('expired')
    ExpireReversalsJob.perform_now
    expect(instrument.signals.count).to eq(1)
  end
end
