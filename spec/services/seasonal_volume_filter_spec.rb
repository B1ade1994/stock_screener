require 'rails_helper'

RSpec.describe 'Seasonal volume visibility' do
  let(:instrument) { create_instrument }
  let(:at) { Time.current.beginning_of_minute - 1.minute }
  around { |e| travel_to(Time.zone.local(2026, 10, 7, 12, 0, 36)) { e.run } }

  def seed(baseline: 200, samples: 10)
    dates = (1..30).map { |n| at.to_date - n }.reject { |d| d.saturday? || d.sunday? }.first(samples)
    dates.each do |date|
      instrument.minute_volume_samples.create!(time: Time.zone.local(date.year, date.month, date.day, 11, 59),
        trading_date: date, minute_of_day: 719, day_type: 'weekday', volume: baseline, data_source: 't_invest')
    end
    20.times do |i|
      instrument.market_minutes.create!(time: at - (20-i).minutes, session: 'test', complete: true,
        buy: 80, sell: 20, open_price: 100, close_price: 100, high_price: 100.04, low_price: 99.96)
    end
    instrument.market_minutes.create!(time: at, session: 'test', complete: true,
      buy: 350, sell: 50, open_price: 100, close_price: 101, high_price: 101, low_price: 100)
  end

  it 'silently retains price-moving local spikes that are ordinary for the time of day' do
    bar = seed
    SignalEvaluator.volume(instrument, bar)
    signal = instrument.signals.where(kind: 'volume').sole
    expect(signal).to be_research_only
    expect(signal.details['decision']).to include('version' => 2, 'passed' => false, 'price_passed' => true, 'reason' => 'ordinary_for_time_of_day')
    expect(signal.details.dig('decision', 'time_baseline')).to include('baseline' => 200, 'ratio' => 2.0, 'samples' => 10, 'passed' => false)
    expect(signal.reaction).to be_present
    expect(instrument.signals.where(kind: VolumeFollowThrough::KIND).sole).to be_research_only
    instrument.minute_volume_samples.update_all(volume: 50)
    expect { SignalEvaluator.volume(instrument, bar) }.not_to change(MarketSignal, :count)
    expect(signal.reload.details.dig('decision', 'time_baseline', 'baseline')).to eq(200)
  end

  it 'allows anomalies that exceed both baselines and keeps the follow-through experimental' do
    SignalEvaluator.volume(instrument, seed(baseline: 100))
    signal = instrument.signals.where(kind: 'volume').sole
    expect(signal).not_to be_research_only
    expect(signal.details.dig('decision', 'time_baseline', 'passed')).to be true
    trial = instrument.signals.where(kind: VolumeFollowThrough::KIND).sole
    expect(trial).to be_research_only
    expect(trial.reversal_status).to eq('possible')
  end

  it 'keeps the previous price filter active while historical observations accumulate' do
    SignalEvaluator.volume(instrument, seed(samples: 9))
    signal = instrument.signals.where(kind: 'volume').sole
    expect(signal).not_to be_research_only
    expect(signal.details.dig('decision', 'time_baseline')).to include('status' => 'warming_up', 'samples' => 9)
  end

  it 'respects the instrument noise-filter switch without losing the diagnostic measurements' do
    instrument.update!(volume_noise_filter: false)
    SignalEvaluator.volume(instrument, seed)
    signal = instrument.signals.where(kind: 'volume').sole
    expect(signal).not_to be_research_only
    expect(signal.details['decision']).to include('enabled' => false, 'passed' => false)
  end
end
