# Two frozen, silent prospective hypotheses. No historical candidates are seeded.
class TechnicalStudies
  STRUCTURE = 'pullback_structure_v1'
  FALSE_BREAKOUT = 'false_breakout_v1'
  WINDOWS = { STRUCTURE => 20.minutes, FALSE_BREAKOUT => 15.minutes }.freeze
  DELIVERY_GRACE = 2.minutes

  def self.initial_state(signal)
    d = signal.details
    now = Time.current
    # A delayed source must not replay a pullback/return that ended before its registration.
    first_previous = now.beginning_of_minute - 1.minute
    if signal.kind == 'reversal' && !signal.experiment &&
        %w[up down].include?(d['direction']) && d['last_checked_at'].present? &&
        %w[extreme volatility rebound_boundary entry_price].all? { |key| TechnicalContext.number(d[key]) }
      { 'experiment' => STRUCTURE, 'status' => 'pending', 'checked_at' => [Time.iso8601(d['last_checked_at']), first_previous].max.iso8601,
        'registered_at' => now.iso8601, 'peak' => d['rebound_boundary'].to_s,
        'previous_close' => d['entry_price'].to_s }
    elsif signal.kind == 'crossing' && d['strength_grade'] == 3 &&
        %w[support resistance].include?(d['side']) && %w[lower upper buffer price].all? { |key| TechnicalContext.number(d[key]) }
      { 'experiment' => FALSE_BREAKOUT, 'status' => 'pending', 'checked_at' => [signal.occurred_at.beginning_of_minute - 1.minute, first_previous].max.iso8601,
        'registered_at' => now.iso8601, 'outside_extreme' => d['price'].to_s }
    end
  end

  def self.process(signal, now: Time.current)
    state = signal.details['technical_study']&.deep_dup
    return unless state && state['status'] == 'pending' && WINDOWS.key?(state['experiment'])
    unless signal.instrument.enabled? && !signal.instrument.expired?
      return finish(signal, state, 'expired', 'observation_disabled', now)
    end
    previous = Time.iso8601(state.fetch('checked_at'))
    deadline = Time.iso8601(state.fetch('registered_at')) + WINDOWS.fetch(state['experiment'])
    through = (now - 95.seconds).beginning_of_minute
    signal.instrument.reversal_minutes.where(time: (previous + 60)..through).order(:time).each do |bar|
      break unless bar.time - previous == 60
      break unless Detectors::Reversal.valid_bar?(bar)
      if bar.time + 60 > deadline || bar.time.in_time_zone.to_date != signal.occurred_at.in_time_zone.to_date
        return finish(signal, state, 'expired', 'window_ended', now)
      end
      outcome = state['experiment'] == STRUCTURE ? advance_structure(signal, state, bar) : advance_false_breakout(signal, state, bar)
      state['checked_at'] = bar.time.iso8601
      if outcome == 'cancelled'
        return finish(signal, state, 'cancelled', 'structure_invalidated', now)
      elsif outcome == 'confirmed'
        if now > deadline + DELIVERY_GRACE || now > bar.time + 60 + DELIVERY_GRACE
          return finish(signal, state, 'expired', 'delayed_confirmation', now)
        end
        emit(signal, state, bar, now)
        return finish(signal, state, 'confirmed', 'rules_met', now)
      end
      previous = bar.time
    end
    if now > deadline + DELIVERY_GRACE
      finish(signal, state, 'expired', 'no_timely_confirmation_or_missing_minutes', now)
    else
      signal.update!(details: signal.details.merge('technical_study' => state))
    end
  end

  def self.advance_structure(signal, state, bar)
    d = signal.details
    sign = d['direction'] == 'up' ? 1 : -1
    extreme = d.fetch('extreme').to_d
    adverse = sign == 1 ? bar.low_price : bar.high_price
    return 'cancelled' if sign * (adverse - extreme) <= 0
    peak = state.fetch('peak').to_d
    favorable = sign == 1 ? bar.high_price : bar.low_price
    if state['pullback_at']
      boundary = d.fetch('rebound_boundary').to_d
      if sign * (bar.close_price - peak) > 0 && sign * (bar.close_price - boundary) >= d.fetch('volatility').to_d * BigDecimal('0.1')
        return 'confirmed'
      end
    elsif sign * (bar.close_price - state.fetch('previous_close').to_d) < 0 && sign * (favorable - peak) < 0
      state['pullback_at'] = (bar.time + 60).iso8601
      state['pullback_extreme'] = adverse.to_s
    elsif sign * (favorable - peak) > 0
      state['peak'] = favorable.to_s
    end
    state['previous_close'] = bar.close_price.to_s
    nil
  end

  def self.advance_false_breakout(signal, state, bar)
    d = signal.details
    up_break = d['side'] == 'resistance'
    buffer = d.fetch('buffer').to_d
    extreme = state.fetch('outside_extreme').to_d
    if state['returned_at']
      invalidated = up_break ? bar.high_price >= extreme + buffer : bar.low_price <= extreme - buffer
      return 'cancelled' if invalidated
      boundary = state.fetch('return_boundary').to_d
      confirmed = up_break ? bar.close_price < boundary - buffer : bar.close_price > boundary + buffer
      return 'confirmed' if confirmed
    else
      state['outside_extreme'] = (up_break ? [extreme, bar.high_price].max : [extreme, bar.low_price].min).to_s
      returned = up_break ? bar.close_price < d.fetch('upper').to_d - buffer : bar.close_price > d.fetch('lower').to_d + buffer
      if returned
        state['returned_at'] = (bar.time + 60).iso8601
        state['return_boundary'] = (up_break ? bar.low_price : bar.high_price).to_s
      end
    end
    nil
  end

  def self.emit(source, state, bar, now)
    structure = state['experiment'] == STRUCTURE
    direction = structure ? source.details.fetch('direction') : (source.details['side'] == 'resistance' ? 'down' : 'up')
    invalidation = if structure
      source.details.fetch('extreme').to_d
    else
      state.fetch('outside_extreme').to_d + (direction == 'down' ? 1 : -1) * source.details.fetch('buffer').to_d
    end
    source.instrument.signals.find_or_create_by!(event_key: "#{state['experiment']}:#{source.id}") do |signal|
      signal.assign_attributes(kind: structure ? 'reversal_structure' : 'false_breakout', research_only: true,
        experiment: state.fetch('experiment'), occurred_at: bar.time + 60,
        title: structure ? 'Отскок, отдельный откат и пробой вершины' : 'Ложный пробой сильной зоны: возврат и продолжение',
        details: { direction: direction, parent_signal_id: source.id, price: bar.close_price.to_s,
          invalidation: invalidation.to_s, decision_at: now.iso8601, confirmed_bar_at: (bar.time + 60).iso8601,
          setup: state.slice('peak', 'pullback_at', 'pullback_extreme', 'returned_at', 'return_boundary', 'outside_extreme'),
          rules: { version: 1, primary_horizon: TechnicalContext::PRIMARY_HORIZON,
            window_minutes: WINDOWS.fetch(state['experiment']) / 60, delivery_grace_seconds: DELIVERY_GRACE.to_i } })
    end
  end

  def self.finish(signal, state, status, reason, now)
    state.merge!('status' => status, 'reason' => reason, 'finished_at' => now.iso8601)
    signal.update!(details: signal.details.merge('technical_study' => state))
  end
end
