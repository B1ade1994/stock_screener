class ReversalResearch
  WINDOW = 20.minutes
  def self.process(instrument, through)
    instrument.signals.where(kind: 'reversal', experiment: nil).where("details ? 'rebound_boundary'")
      .where("COALESCE(details ->> 'structure_status', 'pending') = 'pending'").find_each do |signal|
      previous = Time.iso8601(signal.details['structure_checked_at'] || signal.details.fetch('last_checked_at'))
      instrument.reversal_minutes.where(time: (previous + 60)..through).order(:time).each do |bar|
        break unless bar.time - previous == 60
        break unless advance(signal, bar)
        previous = bar.time
      end
    end
  end

  def self.advance(signal, bar)
    d = signal.details.deep_dup
    if bar.time + 60 > signal.occurred_at + WINDOW || bar.time.in_time_zone.to_date != signal.occurred_at.in_time_zone.to_date
      signal.update!(details: d.merge('structure_status' => 'expired'))
      return false
    end
    return false unless Detectors::Reversal.valid_bar?(bar)
    up = d['direction'] == 'up'
    sign = up ? 1 : -1
    atr = d.fetch('volatility').to_d
    extreme = d.fetch('extreme').to_d
    if up ? bar.low_price < extreme - atr * 0.1 : bar.high_price > extreme + atr * 0.1
      signal.update!(details: d.merge('structure_status' => 'cancelled'))
      return false
    end
    boundary = d.fetch('rebound_boundary').to_d
    beyond = sign * (bar.close_price - boundary) >= atr * 0.1
    # Retest must be a later minute, after a previously observed breakout.
    retest = bar.low_price <= boundary + atr * 0.25 && bar.high_price >= boundary - atr * 0.25
    if d['structure_broken_at'] && retest && beyond
      signal.instrument.signals.find_or_create_by!(event_key: "structure:#{signal.id}") do |trial|
        trial.assign_attributes(kind: 'reversal_structure', research_only: true, experiment: 'structure_v1',
          occurred_at: bar.time + 60, title: 'Пробой экстремума отскока и ретест',
          details: { direction: d.fetch('direction'), parent_signal_id: signal.id, boundary: boundary.to_s,
            version: 1, decision_at: Time.current.iso8601, price: bar.close_price.to_s })
      end
      d['structure_status'] = 'confirmed'
    elsif beyond
      d['structure_broken_at'] ||= (bar.time + 60).iso8601
    elsif sign * (bar.close_price - boundary) < -atr * 0.25
      d.delete('structure_broken_at')
    end
    d['structure_checked_at'] = bar.time.iso8601
    signal.update!(details: d)
    d['structure_status'] != 'confirmed'
  end

  def self.expire
    MarketSignal.where(kind: 'reversal', experiment: nil).where("details ? 'rebound_boundary'")
      .where("COALESCE(details ->> 'structure_status', 'pending') = 'pending'")
      .where('occurred_at < ?', Time.current - WINDOW - 2.minutes).find_each do |signal|
      signal.instrument.with_lock do
        signal.reload
        next unless signal.details.fetch('structure_status', 'pending') == 'pending'
        signal.update!(details: signal.details.merge('structure_status' => 'expired'))
      end
    rescue ActiveRecord::RecordNotFound
      next
    end
  end
end
