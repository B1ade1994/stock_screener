# Forward-only hypothetical marks, not orders or fills. A closed minute's open
# is used only at the exact next minute after a real processing decision.
class HintLifecycle
  GRACE = 10.minutes

  def self.next_minute(time) = Time.at((time.to_i / 60 + 1) * 60).utc

  def self.start(details, now:)
    details['lifecycle'] = { 'status' => 'pending', 'entry_at' => next_minute(now).iso8601,
      'confirmation_received_at' => now.iso8601, 'version' => 1 }
  end

  def self.close(details, now:, reason:, complete: true)
    state = details['lifecycle']
    return unless state && !state['exit_at']
    state.merge!('exit_at' => next_minute(now).iso8601, 'exit_decision_at' => now.iso8601,
      'exit_reason' => reason, 'monitoring_complete' => complete)
  end

  def self.refresh(hint, now:)
    state = hint.details['lifecycle']&.deep_dup
    return unless state && state['status'] == 'pending'
    entry_at = Time.iso8601(state.fetch('entry_at'))
    exit_at = state['exit_at'] && Time.iso8601(state['exit_at'])
    if exit_at && exit_at <= entry_at
      unavailable(state, 'Сценарий завершился до минуты условного входа')
      hint.update!(details: hint.details.merge('lifecycle' => state))
      return
    end
    finish = exit_at || (now - 95.seconds).beginning_of_minute
    return if finish < entry_at
    bars = hint.instrument.reversal_minutes.where(time: entry_at..finish).where('time <= ?', now - 95.seconds).order(:time).to_a
    entry = bars.find { |b| b.time == entry_at }
    if entry.nil?
      unavailable(state, 'Нет свечи в минуту условного входа') if now >= entry_at + GRACE
    else
      state['entry_price'] = entry.open_price.to_s
      if exit_at
        exit_bar = bars.find { |b| b.time == exit_at }
        if exit_bar && now >= exit_at + 95.seconds
          window = bars.select { |b| b.time < exit_at }
          expected = ((exit_at - entry_at) / 60).to_i
          valid = window.size == expected && (window + [exit_bar]).all? { |b| Detectors::Reversal.valid_bar?(b) }
          if valid && state['monitoring_complete'] != false
            sign = hint.details['direction'] == 'up' ? 1 : -1
            change = ->(price) { ((price / entry.open_price - 1) * 100 * sign).round(6).to_f }
            # Exit is at the open: the exit candle's later high/low must not leak in.
            marks = window.flat_map { |b| [b.low_price, b.high_price] } + [entry.open_price, exit_bar.open_price]
            state.merge!('status' => 'measured', 'exit_price' => exit_bar.open_price.to_s,
              'signed_change_percent' => change.call(exit_bar.open_price),
              'adverse_percent' => marks.map { |p| change.call(p) }.min,
              'favorable_percent' => marks.map { |p| change.call(p) }.max, 'candles' => expected)
          else
            unavailable(state, 'Контроль отмены или история между входом и выходом неполные')
          end
        elsif now >= exit_at + GRACE
          unavailable(state, 'Нет свечи в минуту условного выхода')
        end
      end
    end
    hint.update!(details: hint.details.merge('lifecycle' => state))
  end

  def self.statistics(date:)
    from = Time.zone.local(date.year, date.month, date.day)
    hints = MarketSignal.where(kind: DirectionalHints::KIND, confirmed_at: from...from + 1.day).to_a
    [DirectionalHints::EXPERIMENT, DirectionalHintResearch::EXPERIMENT].map do |version|
      group = hints.select { |h| h.experiment == version }
      states = group.filter_map { |h| h.details['lifecycle'] }
      measured = states.select { |s| s['status'] == 'measured' }
      { version: version, total: group.size, measured: measured.size,
        positive: measured.count { |s| s.fetch('signed_change_percent').positive? },
        mean: measured.any? ? measured.sum { |s| s.fetch('signed_change_percent') } / measured.size : nil,
        pending: states.count { |s| s['status'] == 'pending' },
        unavailable: states.count { |s| s['status'] == 'unavailable' }, legacy: group.size - states.size }
    end
  end

  def self.unavailable(state, reason)
    state.merge!('status' => 'unavailable', 'reason' => reason)
  end
end
