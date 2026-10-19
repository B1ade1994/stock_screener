class VolumeTimeBaseline
  VERSION = 'minute_of_day_v1'
  MINIMUM_SAMPLES = 10
  MAXIMUM_SAMPLES = 20

  def self.evaluate(instrument:, bar:)
    local = bar.time.in_time_zone('Europe/Moscow')
    date = local.to_date
    minute = local.hour * 60 + local.min
    day_type = MinuteVolumeSample.day_type(date)
    samples = instrument.minute_volume_samples.where(minute_of_day: minute, day_type: day_type)
      .where(trading_date: (date - MinuteVolumeSample::RETENTION_DAYS)...date)
      .order(trading_date: :desc).limit(MAXIMUM_SAMPLES).pluck(:volume, :trading_date)
    result = { version: VERSION, minute_of_day: minute, day_type: day_type,
      samples: samples.size, minimum_samples: MINIMUM_SAMPLES, multiplier: instrument.volume_multiplier.to_f,
      first_date: samples.last&.last&.iso8601, last_date: samples.first&.last&.iso8601,
      status: 'warming_up', baseline: nil, ratio: nil, passed: nil }
    return result if samples.size < MINIMUM_SAMPLES

    volumes = samples.map(&:first).sort
    middle = volumes.size / 2
    baseline = volumes.size.odd? ? volumes[middle].to_f : (volumes[middle - 1] + volumes[middle]) / 2.0
    return result.merge(status: 'zero_baseline', baseline: 0.0) unless baseline.positive?

    result.merge(status: 'ready', baseline: baseline, ratio: (bar.volume / baseline).round(2),
      passed: bar.volume >= baseline * instrument.volume_multiplier)
  end
end
