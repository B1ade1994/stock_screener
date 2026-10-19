class ArchiveMinuteVolumesJob < ApplicationJob
  limits_concurrency to: 1, key: 'archive-minute-volumes', duration: 10.minutes

  def perform(now = Time.current)
    # Rails stores these timestamp-without-time-zone columns in UTC.
    # Only real, finalized OHLCV rows are copied; gaps never become zero volume.
    cutoff = now.in_time_zone('Europe/Moscow').to_date - MinuteVolumeSample::RETENTION_DAYS
    connection = MinuteVolumeSample.connection
    connection.execute(<<~SQL)
      INSERT INTO minute_volume_samples (instrument_id, time, trading_date, minute_of_day, day_type, volume, data_source)
      SELECT instrument_id, time, local_time::date,
        (EXTRACT(HOUR FROM local_time) * 60 + EXTRACT(MINUTE FROM local_time))::integer,
        CASE EXTRACT(ISODOW FROM local_time) WHEN 6 THEN 'saturday' WHEN 7 THEN 'sunday' ELSE 'weekday' END,
        volume, data_source
      FROM (
        SELECT *, time AT TIME ZONE 'UTC' AT TIME ZONE 'Europe/Moscow' AS local_time
        FROM reversal_minutes
        WHERE time <= #{connection.quote((now - 95.seconds).utc)} AND volume >= 0
      ) minutes
      WHERE local_time::date >= #{connection.quote(cutoff)}
      ON CONFLICT (instrument_id, time) DO UPDATE
        SET volume = EXCLUDED.volume, data_source = EXCLUDED.data_source
        WHERE (minute_volume_samples.volume, minute_volume_samples.data_source)
          IS DISTINCT FROM (EXCLUDED.volume, EXCLUDED.data_source)
    SQL
    MinuteVolumeSample.where('trading_date < ?', cutoff).delete_all
  end
end
