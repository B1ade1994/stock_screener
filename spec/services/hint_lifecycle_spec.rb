require 'rails_helper'

RSpec.describe HintLifecycle do
  let(:instrument) { create_instrument(reversal_enabled: false, enabled: false) }
  let(:start) { Time.zone.local(2026, 10, 1, 14, 0, 36) }
  around { |e| travel_to(start) { e.run } }

  def signal(direction: 'up')
    details = { 'direction' => direction, 'monitoring' => false }
    described_class.start(details, now: start)
    instrument.signals.create!(kind: 'directional_hint', title: 'Test', event_key: SecureRandom.uuid,
      research_only: true, experiment: 'directional_v1', occurred_at: start,
      reversal_status: 'confirmed', confirmed_at: start, details: details)
  end

  def candle(at, opening: 100, closing: opening, low: [opening, closing].min - 1, high: [opening, closing].max + 1)
    instrument.reversal_minutes.create!(time: at, open_price: opening, close_price: closing,
      low_price: low, high_price: high, volume: 100, data_source: 't_invest')
  end

  it 'uses the first minute after detection, never the ideal boundary or later extremes' do
    hint = signal
    entry = start.beginning_of_minute + 1.minute
    3.times { |i| candle(entry + i.minutes) }
    cancellation_received = entry + 2.minutes + 36.seconds
    DirectionalHints.finish(hint, 'cancelled', 'Цена достигла границы отмены сценария', now: cancellation_received)
    exit_at = entry + 3.minutes
    candle(exit_at, opening: 98, closing: 105, low: 90, high: 120)
    travel_to exit_at + 96.seconds
    described_class.refresh(hint, now: Time.current)
    result = hint.reload.details['lifecycle']
    expect(result).to include('status' => 'measured', 'signed_change_percent' => -2.0,
      'adverse_percent' => -2.0, 'favorable_percent' => 1.0, 'candles' => 3)
    expect(result['exit_price'].to_d).to eq(98)
    expect(Time.iso8601(result['entry_at'])).to eq(entry)
    expect(Time.iso8601(result['exit_at'])).to eq(exit_at)
    expect(hint.reactions.count).to eq(2) # fixed-window reactions remain available
  end

  it 'signs a short result correctly and includes unfavorable moves before the exit' do
    hint = signal(direction: 'down')
    entry = start.beginning_of_minute + 1.minute
    candle(entry, high: 103)
    candle(entry + 1.minute, opening: 98)
    d = hint.details.deep_dup
    described_class.close(d, now: entry + 36.seconds, reason: 'Отмена')
    hint.update!(details: d)
    described_class.refresh(hint, now: entry + 3.minutes)
    expect(hint.reload.details['lifecycle']).to include('status' => 'measured',
      'signed_change_percent' => 2.0, 'adverse_percent' => -3.0)
  end

  it 'rejects missing intermediate minutes instead of reporting a profit' do
    hint = signal
    entry = start.beginning_of_minute + 1.minute
    candle(entry)
    candle(entry + 3.minutes, opening: 105)
    d = hint.details.deep_dup
    described_class.close(d, now: entry + 2.minutes + 36.seconds, reason: 'Отмена')
    hint.update!(details: d)
    described_class.refresh(hint, now: entry + 5.minutes)
    expect(hint.reload.details['lifecycle']).to include('status' => 'unavailable')
    expect(hint.details['lifecycle']).not_to have_key('signed_change_percent')
  end

  it 'does not substitute a later candle for a missing exit' do
    hint = signal
    entry = start.beginning_of_minute + 1.minute
    candle(entry)
    candle(entry + 2.minutes, opening: 105)
    d = hint.details.deep_dup
    described_class.close(d, now: entry + 36.seconds, reason: 'Отмена')
    hint.update!(details: d)
    described_class.refresh(hint, now: entry + 12.minutes)
    expect(hint.reload.details['lifecycle']).to include('status' => 'unavailable', 'reason' => 'Нет свечи в минуту условного выхода')
  end

  it 'marks a missing entry unavailable and does not fabricate a historical lifecycle' do
    hint = signal
    legacy = instrument.signals.create!(kind: 'directional_hint', title: 'Old', event_key: 'legacy', occurred_at: start,
      confirmed_at: start, reversal_status: 'confirmed', experiment: 'directional_v1', research_only: true, details: {})
    described_class.refresh(hint, now: start + 15.minutes)
    described_class.refresh(legacy, now: start + 15.minutes)
    expect(hint.reload.details['lifecycle']['status']).to eq('unavailable')
    expect(legacy.reload.details).not_to have_key('lifecycle')
    row = described_class.statistics(date: start.to_date).first
    expect(row).to include(total: 2, measured: 0, unavailable: 1, legacy: 1)
  end

  it 'finishes pending accounting for a disabled instrument through the existing job' do
    hint = signal
    entry = start.beginning_of_minute + 1.minute
    candle(entry)
    candle(entry + 1.minute, opening: 99)
    d = hint.details.deep_dup
    described_class.close(d, now: entry + 36.seconds, reason: 'Отмена')
    hint.update!(details: d)
    travel_to entry + 3.minutes
    RefreshDirectionalHintsJob.perform_now
    expect(hint.reload.details['lifecycle']['status']).to eq('measured')
  end

  it 'does not turn a late exit into a complete result after incomplete cancellation monitoring' do
    hint = signal
    entry = start.beginning_of_minute + 1.minute
    2.times { |i| candle(entry + i.minutes) }
    d = hint.details.deep_dup
    described_class.close(d, now: entry + 36.seconds, reason: 'Есть пропуски контроля', complete: false)
    hint.update!(details: d)
    described_class.refresh(hint, now: entry + 3.minutes)
    expect(hint.reload.details['lifecycle']['status']).to eq('unavailable')
  end
  it 'does not count an idea cancelled before its entry minute as a flat trade' do
    hint = signal
    DirectionalHints.finish(hint, 'cancelled', 'Конфликт', now: start + 5.seconds)
    described_class.refresh(hint, now: start + 2.minutes)
    expect(hint.reload.details['lifecycle']).to include('status' => 'unavailable',
      'reason' => 'Сценарий завершился до минуты условного входа')
    expect(hint.details['lifecycle']).not_to have_key('signed_change_percent')
  end

end
