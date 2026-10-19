class SignalReaction < ApplicationRecord
  HORIZONS = [5, 15, 30, 60].freeze
  SETTLE_DELAY = 30.seconds
  MISSING_GRACE = 10.minutes
  MAX_RETRY_AGE = 24.hours
  RECOVERY_INTERVAL = 5.minutes
  QUALITY_LABELS = {
    'missing_start' => 'Нет начальной свечи', 'missing_end' => 'Нет конечной свечи',
    'missing_minutes' => 'Пропуски внутри окна', 'history_unavailable' => 'Ошибка загрузки истории',
    'legacy_unknown' => 'Причина не сохранена'
  }.freeze

  belongs_to :signal, class_name: "MarketSignal"
  validates :phase, inclusion: { in: %w[initial confirmation] }
  scope :due, ->(now) { where("next_check_at <= ?", now) }

  def pending_horizons = HORIZONS.reject { |minutes| results.key?(minutes.to_s) }

  def recovery_deadline(minutes) = reference_at + minutes.minutes + MAX_RETRY_AGE

  def refreshable_horizons(now:)
    HORIZONS.select do |minutes|
      result = results[minutes.to_s]
      result.nil? || (incomplete?(result, minutes) && now < recovery_deadline(minutes))
    end
  end

  def incomplete?(result, minutes)
    result['status'] != 'measured' || result['candles'].to_i != minutes
  end

  def quality_code(result, minutes)
    return result['quality_code'] if result['quality_code'].in?(QUALITY_LABELS.keys)
    return 'missing_minutes' if result['status'] == 'measured' && result['candles'].to_i != minutes
    case result['reason']
    when 'Нет начальной биржевой свечи' then 'missing_start'
    when 'Нет биржевой свечи в конце интервала' then 'missing_end'
    when 'Историю не удалось получить за 24 часа' then 'history_unavailable'
    else 'legacy_unknown'
    end
  end

  def schedule_next_check(now:)
    candidates = refreshable_horizons(now: now).map do |minutes|
      if results.key?(minutes.to_s)
        [now + RECOVERY_INTERVAL, recovery_deadline(minutes)].min
      else
        [reference_at + minutes.minutes + SETTLE_DELAY, now + 1.minute].max
      end
    end
    self.next_check_at = candidates.min
  end

  def unavailable!(reason)
    remaining = pending_horizons.to_h { |h| [h.to_s, { "status" => "unavailable", "reason" => reason,
      "quality_code" => 'history_unavailable' }] }
    update!(results: results.merge(remaining), next_check_at: nil, last_error: nil)
  end
end
