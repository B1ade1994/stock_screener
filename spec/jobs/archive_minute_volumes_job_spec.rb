require 'rails_helper'

RSpec.describe ArchiveMinuteVolumesJob do
  let(:instrument) { create_instrument(reversal_enabled: false) }
  around { |e| travel_to(Time.zone.local(2026, 10, 7, 12, 0)) { e.run } }

  def minute(time, volume: 123, source: 'stream')
    instrument.reversal_minutes.create!(time: time, volume: volume, data_source: source,
      open_price: 100, close_price: 101, low_price: 99, high_price: 102)
  end

  it 'archives exact Moscow minutes, splits weekdays and weekends, and never fills missing minutes' do
    minute(Time.utc(2026, 9, 28, 21, 3))
    minute(Time.zone.local(2026, 10, 3, 10), volume: 0)
    minute(Time.zone.local(2026, 10, 4, 10))
    described_class.perform_now
    samples = instrument.minute_volume_samples.order(:time)
    expect(samples.size).to eq(3)
    expect(samples.first).to have_attributes(trading_date: Date.new(2026, 9, 29), minute_of_day: 3, day_type: 'weekday', volume: 123)
    expect(samples.second).to have_attributes(day_type: 'saturday', volume: 0)
    expect(samples.third.day_type).to eq('sunday')
    expect { described_class.perform_now }.not_to change(MinuteVolumeSample, :count)
  end

  it 'waits for finalized minutes and accepts corrections from canonical API history' do
    old = minute(2.minutes.ago)
    minute(1.minute.ago)
    minute(1.minute.from_now)
    described_class.perform_now
    expect(MinuteVolumeSample.count).to eq(1)
    old.update!(volume: 456, data_source: 't_invest')
    described_class.perform_now
    expect(MinuteVolumeSample.sole).to have_attributes(volume: 456, data_source: 't_invest')
  end

  it 'archives before raw retention runs, retains 90 days, and removes samples with their instrument' do
    old = minute(8.days.ago)
    PruneMinutesJob.perform_now
    expect(ReversalMinute.exists?(old.id)).to be false
    expect(instrument.minute_volume_samples.sole.volume).to eq(123)
    travel 83.days
    described_class.perform_now
    expect(MinuteVolumeSample.count).to eq(0)
    minute(2.minutes.ago)
    described_class.perform_now
    expect { instrument.destroy! }.to change(MinuteVolumeSample, :count).by(-1)
  end

  it 'leaves source minutes intact if archiving fails' do
    old = minute(8.days.ago)
    allow(described_class).to receive(:perform_now).and_raise('archive unavailable')
    expect { PruneMinutesJob.perform_now }.to raise_error('archive unavailable')
    expect(ReversalMinute.exists?(old.id)).to be true
  end
end
