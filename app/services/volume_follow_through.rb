# Prospective shadow experiment. Never changes the source episode or emits alerts.
class VolumeFollowThrough
  KIND = 'volume_followthrough'
  VERSION = 'volume_hold_v1'

  def self.register(episode)
    burst = episode.details.fetch('bursts').first
    quality = burst.fetch('quality', {})
    opening, closing = burst.values_at('open_price', 'close_price').map { |v| v.to_d }
    threshold = [0.15, quality['threshold_percent'].to_f].max
    valid = opening.positive? && closing.positive? && quality['atr_percent'].present?
    change = valid ? ((closing / opening - 1) * 100).to_f : nil
    passed = valid && change.abs >= threshold
    episode.instrument.signals.create!(kind: KIND, experiment: VERSION, research_only: true,
      event_key: "#{VERSION}:#{episode.id}", occurred_at: episode.occurred_at,
      title: 'Эксперимент объёма: движение и удержание', reversal_status: passed ? 'possible' : 'rejected',
      details: { source_id: episode.id, direction: closing > opening ? 'up' : 'down',
        open: opening.to_s, close: closing.to_s, ratio: burst['ratio'], threshold_percent: threshold,
        change_percent: change, reason: passed ? 'awaiting_hold' : valid ? 'small_move' : 'missing_prices',
        reference_at: (Time.current.beginning_of_minute + 1.minute).iso8601 })
  end

  def self.process(instrument)
    instrument.with_lock do
      instrument.signals.where(kind: KIND, reversal_status: 'possible').find_each do |trial|
        reference = Time.iso8601(trial.details.fetch('reference_at'))
        next if Time.current < reference + 2.minutes + 35.seconds
        if Time.current >= reference + 5.minutes
          finish(trial, 'expired', 'confirmation_timeout')
          next
        end
        bars = instrument.reversal_minutes.where(time: [reference, reference + 1.minute]).order(:time).to_a
        next unless bars.size == 2
        sign = trial.details['direction'] == 'up' ? 1 : -1
        midpoint = (trial.details['open'].to_d + trial.details['close'].to_d) / 2
        held = bars.all? { |b| (b.close_price - midpoint) * sign > 0 } &&
          (bars.last.close_price - bars.first.close_price) * sign >= 0
        finish(trial, held ? 'confirmed' : 'rejected', held ? 'held' : 'returned')
      end
    end
  end

  def self.expire
    MarketSignal.where(kind: KIND, reversal_status: 'possible').where('created_at < ?', 7.minutes.ago).find_each do |trial|
      trial.instrument.with_lock do
        trial.reload
        finish(trial, 'expired', 'missing_minutes') if trial.reversal_status == 'possible'
      end
    rescue ActiveRecord::RecordNotFound
      next
    end
  end

  def self.finish(trial, status, reason)
    trial.update!(reversal_status: status, details: trial.details.merge('reason' => reason, 'decided_at' => Time.current.iso8601))
  end
end
