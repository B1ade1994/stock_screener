require 'rails_helper'

RSpec.describe VolumeTimeBaseline do
  let(:instrument) { create_instrument }
  let(:at) { Time.zone.local(2026, 10, 7, 11, 59) }
  let(:bar) { MarketMinute.new(time: at, buy: 400, sell: 0, unknown: 0) }
  let(:dates) { (1..80).map { |n| at.to_date - n }.reject { |d| d.saturday? || d.sunday? } }

  def sample(date, volume: 100, instrument: self.instrument, minute: 719)
    instrument.minute_volume_samples.create!(time: Time.zone.local(date.year, date.month, date.day) + minute.minutes,
      trading_date: date, minute_of_day: minute, day_type: MinuteVolumeSample.day_type(date), volume: volume, data_source: 'stream')
  end

  def evaluate = described_class.evaluate(instrument: instrument, bar: bar)

  it 'does not block during warmup and activates on ten observations using an unrounded threshold' do
    dates.first(9).each { |d| sample(d, volume: 200) }
    expect(evaluate).to include(status: 'warming_up', samples: 9, passed: nil)
    sample(dates[9], volume: 200)
    expect(evaluate).to include(status: 'ready', samples: 10, baseline: 200, ratio: 2.0, passed: false)
    bar.buy = 599
    expect(evaluate).to include(ratio: 3.0, passed: false)
    bar.buy = 600
    expect(evaluate).to include(passed: true)
  end

  it 'uses only the latest twenty previous matching dates for this instrument and exact minute' do
    dates.first(10).each { |d| sample(d, volume: 100) }
    dates.drop(10).first(10).each { |d| sample(d, volume: 300) }
    sample(dates[20], volume: 999_999)
    sample(at.to_date, volume: 999_999)
    sample(at.to_date + 1, volume: 999_999)
    sample(dates.first, volume: 999_999, minute: 720)
    sample(dates.first, volume: 999_999, instrument: create_instrument)
    sample(Date.new(2026, 10, 3), volume: 999_999)
    sample(Date.new(2026, 10, 4), volume: 999_999)
    sample(at.to_date - 91, volume: 999_999)
    expect(evaluate).to include(samples: 20, baseline: 200, first_date: dates[19].iso8601, last_date: dates.first.iso8601)
  end

  it 'keeps Saturday and Sunday separate from each other and weekdays' do
    bar.time = Time.zone.local(2026, 10, 10, 11, 59)
    10.times { |n| sample(bar.time.to_date - (n + 1) * 7, volume: 50) }
    sample(Date.new(2026, 10, 4), volume: 999_999)
    sample(Date.new(2026, 10, 9), volume: 999_999)
    expect(evaluate).to include(day_type: 'saturday', samples: 10, baseline: 50, passed: true)
  end

  it 'does not use a zero median as an infinite anomaly or treat absent dates as zero' do
    dates.first(10).each { |d| sample(d, volume: 0) }
    expect(evaluate).to include(status: 'zero_baseline', samples: 10, baseline: 0, passed: nil, ratio: nil)
    instrument.minute_volume_samples.delete_all
    sample(dates.first, volume: 100)
    expect(evaluate).to include(status: 'warming_up', samples: 1, baseline: nil)
  end
end
