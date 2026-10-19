require 'rails_helper'

RSpec.describe DirectionalHintResearch do
  let(:instrument) { create_instrument(reversal_enabled: true, breakout_enabled: true) }
  around { |e| travel_to(Time.zone.local(2026, 10, 1, 14, 0, 36)) { e.run } }

  def candle(time:, close: 100, low: close - 0.1, high: close + 0.1)
    instrument.reversal_minutes.create!(time: time, open_price: close, close_price: close,
      high_price: high, low_price: low, volume: 100, data_source: 't_invest')
  end

  def pair(direction: 'up', scenario: 'reversal', experiment: nil)
    b = candle(time: Time.current.beginning_of_minute - 2.minutes)
    control = DirectionalHints.create(instrument, b,
      { direction: direction, extreme: direction == 'up' ? 98 : 102, volatility: 1,
        rebound_boundary: 100, scenario: scenario, source_experiment: experiment },
      key: SecureRandom.uuid, basis: 'Test', now: Time.current)
    [control, instrument.signals.find_by!(event_key: "hint:v2:#{control.id}")]
  end

  def follow(hint, close:, low: close - 0.1, high: close + 0.1)
    at = Time.iso8601(hint.details.fetch('last_checked_at')) + 60
    b = candle(time: at, close: close, low: low, high: high)
    travel_to at + 96.seconds
    described_class.advance_history(hint, at, now: Time.current)
    hint.reload
    b
  end

  it 'pairs a new candidate with the same registration time, source and initial reaction, silently' do
    control, hint = pair
    expect(hint).to have_attributes(experiment: 'directional_v2', research_only: true, created_at: control.created_at)
    expect(hint.details).to include('control_id' => control.id, 'confirmation_rule' => 'two_closes')
    expect(hint.reaction.reference_at).to eq(control.reaction.reference_at)
    expect(instrument.signals.visible).to be_empty
    2.times { DirectionalHints.call(instrument, collect: true) }
    expect(instrument.signals.count).to eq(2)
  end

  %w[up down].each do |direction|
    it "waits for a separate pullback and structure break for #{direction}" do
      _, hint = pair(direction: direction, experiment: 'context_5m_v3')
      sign = direction == 'up' ? 1 : -1
      [0.4, 0.6, 0.8].each { |delta| follow(hint, close: 100 + sign * delta) }
      expect(hint.reversal_status).to eq('possible') # two closes alone are insufficient
      follow(hint, close: 100 + sign * 0.4)
      expect(hint.details['structure']['pullback_at']).to be_present
      follow(hint, close: 100 + sign * 1.0)
      expect(hint.reversal_status).to eq('confirmed')
      expect(hint.details['entry_review']).to include('accepted' => true, 'level_check' => 'no_opposing_level')
      expect(Time.iso8601(hint.details['lifecycle']['entry_at'])).to eq(Time.current.beginning_of_minute + 1.minute)
    end

    it "rejects a late entry for #{direction} while the control can still confirm" do
      control, hint = pair(direction: direction)
      sign = direction == 'up' ? 1 : -1
      2.times { follow(hint, close: 100 + sign * 2.1) }
      expect(hint.reversal_status).to eq('missed')
      expect(hint.details['status_reason']).to include('далеко')
      expect(hint.confirmation_reaction).to be_nil
      expect(hint.details['lifecycle']).to be_nil
      DirectionalHints.advance_history(control, Time.iso8601(hint.details['last_checked_at']), now: Time.current)
      expect(control.reload.reversal_status).to eq('confirmed')
    end
  end

  it 'does not infer a pullback from a candle containing a new peak and a lower close' do
    _, hint = pair(experiment: 'context_5m_v3')
    follow(hint, close: 100.5, high: 101)
    follow(hint, close: 100.4, high: 101.5)
    expect(hint.details['structure']['pullback_at']).to be_nil
    follow(hint, close: 101.7)
    expect(hint.reversal_status).to eq('possible')
  end

  it 'does not accept a structure with a repeated initial extreme' do
    _, hint = pair(experiment: 'context_5m_v3')
    follow(hint, close: 100.4)
    follow(hint, close: 100.2, low: 98)
    follow(hint, close: 101)
    expect(hint.reversal_status).to eq('possible')
    expect(hint.details['structure']['broken']).to be(true)
  end

  it 'requires a separate retest candle and uses minute volatility rather than the daily buffer' do
    at = Time.current.beginning_of_minute - 2.minutes
    20.times { |i| candle(time: at - (20 - i).minutes, close: 101, low: 100.5, high: 101.5) }
    b = candle(time: at, close: 101.2)
    control = DirectionalHints.create(instrument, b,
      { direction: 'up', scenario: 'crossing', extreme: 100, volatility: 1, rebound_boundary: 101, invalidation: 100 },
      key: 'retest', basis: 'Level', now: Time.current)
    hint = instrument.signals.find_by!(experiment: 'directional_v2')
    expect(hint.details['risk_unit'].to_d).to eq(1)
    expect(hint.details['invalidation'].to_d).to eq(99)
    2.times { follow(hint, close: 101.3) }
    expect(hint.reversal_status).to eq('possible')
    follow(hint, close: 101.2, low: 100.0)
    expect(hint.reversal_status).to eq('possible') # same bar may touch and close beyond
    follow(hint, close: 101.3)
    expect(hint.reversal_status).to eq('confirmed')
    expect(control.reload.reversal_status).to eq('possible')
  end

  it 'freezes high-strength opposing zones and does not use levels added after the candidate' do
    [1, 2, 3].each_with_index do |score, i|
      instrument.price_levels.create!(timeframe: 'day', side: 'resistance', price: 101 + i,
        source: 'automatic', status: 'confirmed', active: true, touches: 2,
        assessment: { version: Detectors::Levels::VERSION, score: score })
    end
    _, hint = pair
    snapshot = hint.details['opposing_levels']
    expect(snapshot.size).to eq(1)
    expect(snapshot.first['lower'].to_d).to eq(103)
    instrument.price_levels.update_all(price: 200)
    2.times { follow(hint, close: 100.5) }
    expect(hint.details['opposing_levels']).to eq(snapshot)
    expect(hint.reversal_status).to eq('missed')
    expect(hint.details['entry_review']['room_risk']).to be < 1.5
  end

  it 'rejects a wide invalidation even when the candidate has not moved far' do
    _, hint = pair
    hint.update!(details: hint.details.merge('invalidation' => '90'))
    2.times { follow(hint, close: 100.2) }
    expect(hint.reversal_status).to eq('missed')
    expect(hint.details['status_reason']).to include('расстояние до отмены')
  end

  it 'does not turn a recovered stale confirmation into a fresh entry' do
    _, hint = pair
    previous = Time.iso8601(hint.details['last_checked_at'])
    2.times { |i| candle(time: previous + (i + 1).minutes, close: 100.3) }
    travel 5.minutes
    described_class.advance_history(hint, previous + 2.minutes, now: Time.current)
    expect(hint.reload.reversal_status).to eq('expired')
    expect(hint.confirmed_at).to be_nil
  end

  it 'keeps both arms separate in fixed-horizon statistics and never relabels a missed entry as confirmed' do
    control, hint = pair
    2.times { follow(hint, close: 100.4) }
    DirectionalHints.advance_history(control, Time.iso8601(hint.details['last_checked_at']), now: Time.current)
    rows = DailySignalStatistics.call(date: Date.current, horizon: 15).index_by { |row| row[:key] }
    %w[directional_hint hint_confirmation hint_v2 hint_v2_confirmation].each do |key|
      expect(rows.fetch(key)[:total]).to eq(1)
    end
    expect(rows['levels'][:total]).to eq(0)
  end
  it 'rolls back the control as well if its research pair could not be created' do
    allow(described_class).to receive(:create_from).and_raise(ActiveRecord::RecordInvalid)
    expect { pair }.to raise_error(ActiveRecord::RecordInvalid)
    expect(instrument.signals.count).to eq(0)
    expect(SignalReaction.count).to eq(0)
  end

  it 'never copies an old candidate when the periodic job starts' do
    instrument.signals.create!(kind: 'directional_hint', experiment: 'directional_v1',
      event_key: 'old', title: 'Old', occurred_at: 1.day.ago, created_at: 1.day.ago,
      reversal_status: 'expired', research_only: true, details: { monitoring: false })
    DirectionalHints.call(instrument, collect: true)
    expect(instrument.signals.where(experiment: 'directional_v2')).to be_empty
  end

  it 'does not cross a missing minute or falsely confirm after timeout' do
    _, hint = pair
    previous = Time.iso8601(hint.details['last_checked_at'])
    candle(time: previous + 2.minutes, close: 100.3)
    described_class.advance_history(hint, previous + 2.minutes, now: Time.current)
    expect(hint.reload.details['confirmation_closes']).to eq(0)
    travel 13.minutes
    described_class.advance_history(hint, Time.current - 2.minutes, now: Time.current)
    expect(hint.reload.reversal_status).to eq('expired')
    expect(hint.confirmation_reaction).to be_nil
  end

  it 'retains a standalone active research arm without suppressing a new control source' do
    control, hint = pair
    DirectionalHints.finish(control, 'cancelled', 'Цена достигла границы отмены сценария', now: Time.current)
    instrument.signals.create!(kind: 'reversal', event_key: 'new-source', title: 'New',
      reversal_status: 'possible', occurred_at: 1.minute.ago,
      details: { direction: 'up', extreme: 98, volatility: 1, rebound_boundary: 100 })
    # Existing last bar is 13:58, so a source must already have occurred by its end.
    instrument.signals.find_by!(event_key: 'new-source').update!(occurred_at: Time.current.beginning_of_minute - 1.minute)
    DirectionalHints.call(instrument, collect: true)
    expect(hint.reload.details['monitoring']).to be(true)
    expect(instrument.signals.where(experiment: 'directional_v1').count).to eq(2)
    expect(instrument.signals.where(experiment: 'directional_v2').count).to eq(2)
  end

end
