# Paired prospective experiment. It receives exactly the control candidate,
# never historical candidates, and cannot suppress the control's future ideas.
class DirectionalHintResearch < DirectionalHints
  EXPERIMENT = 'directional_v2'
  MAX_ADVANCE = BigDecimal('2')
  MAX_RISK = BigDecimal('4')
  MIN_ROOM_RISK = BigDecimal('1.5')
  RULE_LABELS = {
    'structure' => 'Откат без нового экстремума, затем закрытие за максимумом/минимумом отскока',
    'retest' => 'Возврат к границе сильной зоны, затем отдельное закрытие за границей подтверждения',
    'two_closes' => 'Два последовательных закрытия за границей подтверждения'
  }.freeze

  def self.create_from(control, bar, now:)
    d = control.details.deep_dup
    rule = if d['scenario'] == 'crossing'
      'retest'
    elsif d['source_experiment'].present?
      'structure'
    else
      'two_closes'
    end
    sign = d['direction'] == 'up' ? 1 : -1
    # A boundary touch must be possible before confirmation in the retest arm.
    d['invalidation'] = (d['extreme'].to_d - sign * d['volatility'].to_d).to_s if rule == 'retest'
    levels = control.instrument.price_levels.active.to_a
    strength = LevelStrength.new(levels)
    opposing = sign == 1 ? 'resistance' : 'support'
    snapshot = levels.select { |l| l.side == opposing && strength.call(l).grade == 3 }.map do |level|
      { id: level.id, lower: level.lower_bound.to_s, upper: level.upper_bound.to_s }
    end
    risk_unit = d['volatility'].to_d
    if rule == 'retest'
      history = control.instrument.reversal_minutes.where('time < ?', bar.time).order(time: :desc).limit(20).to_a.reverse
      risk_unit = minute_range(history, through: bar.time)
    end
    d.merge!('version' => 2, 'control_id' => control.id, 'confirmation_rule' => rule,
      'risk_unit' => risk_unit&.to_s, 'opposing_levels' => snapshot,
      'entry_thresholds' => { 'max_advance' => MAX_ADVANCE.to_s, 'max_risk' => MAX_RISK.to_s, 'min_room_risk' => MIN_ROOM_RISK.to_s },
      'structure' => { 'peak' => (sign == 1 ? bar.high_price : bar.low_price).to_s, 'previous_close' => bar.close_price.to_s },
      'status_reason' => RULE_LABELS.fetch(rule))
    control.instrument.signals.create!(kind: KIND, research_only: true, experiment: EXPERIMENT,
      reversal_status: 'possible', event_key: "hint:v2:#{control.id}", occurred_at: control.occurred_at,
      title: control.title, created_at: control.created_at, details: d)
  end

  def self.minute_range(history, through:)
    return unless history.size == 20 && history.last.time + 60 == through &&
      history.first.time.in_time_zone.to_date == through.in_time_zone.to_date &&
      history.all? { |b| Detectors::Reversal.valid_bar?(b) } && history.each_cons(2).all? { |a, b| b.time == a.time + 60 }
    history.each_with_index.sum do |bar, i|
      previous = i.zero? ? bar.open_price : history[i - 1].close_price
      [bar.high_price - bar.low_price, (bar.high_price - previous).abs, (bar.low_price - previous).abs].max
    end / 20
  end

  def self.advance(hint, bar, now: Time.current)
    return super if hint.confirmed_at
    d = hint.details.deep_dup
    return unless d['monitoring'] && bar.time > Time.iso8601(d.fetch('last_checked_at'))
    deadline = Time.iso8601(d.fetch('confirmation_deadline'))
    return if bar.time + 60 > deadline
    sign = d['direction'] == 'up' ? 1 : -1
    adverse = sign == 1 ? bar.low_price : bar.high_price
    if sign * (adverse - d.fetch('invalidation').to_d) <= 0
      return finish(hint, 'cancelled', 'Цена достигла границы отмены сценария', now: now, bar: bar)
    end
    d['last_checked_at'] = bar.time.iso8601
    ready = confirmation_ready?(d, bar, sign)
    hint.update!(details: d)
    return unless ready
    if now > deadline + 2.minutes || now > bar.time + 60 + 2.minutes
      return finish(hint, 'expired', 'Подтверждение поступило с опозданием', now: now, bar: bar)
    end
    review = entry_review(d, bar.close_price, now: now)
    d['entry_review'] = review
    hint.update!(details: d)
    unless review['accepted']
      return finish(hint, 'missed', review.fetch('reason'), now: now, bar: bar)
    end
    d.merge!('confirmed_bar_at' => (bar.time + 60).iso8601, 'status_at' => now.iso8601,
      'status_reason' => 'Условие сценария и фильтр входа выполнены; исследовательский вариант')
    HintLifecycle.start(d, now: now)
    hint.update!(reversal_status: 'confirmed', confirmed_at: now, details: d)
  end

  def self.confirmation_ready?(d, bar, sign)
    beyond = sign * (bar.close_price - d.fetch('confirmation_price').to_d) >= 0
    case d.fetch('confirmation_rule')
    when 'two_closes'
      d['confirmation_closes'] = beyond ? d.fetch('confirmation_closes') + 1 : 0
      d['confirmation_closes'] >= 2
    when 'retest'
      return beyond if d['retest_at'] # Only a later candle can confirm a touch.
      boundary = d.fetch('extreme').to_d
      near = sign * ((sign == 1 ? bar.low_price : bar.high_price) - boundary) <= d.fetch('volatility').to_d * BigDecimal('0.25')
      d['retest_at'] = bar.time.iso8601 if near && sign * (bar.close_price - boundary) > 0
      false
    when 'structure'
      state = d.fetch('structure')
      extreme = d.fetch('extreme').to_d
      adverse = sign == 1 ? bar.low_price : bar.high_price
      if sign * (adverse - extreme) <= 0
        # A new extreme invalidates this structure even before the wider stop.
        state['broken'] = true
      end
      return false if state['broken']
      peak = state.fetch('peak').to_d
      favorable = sign == 1 ? bar.high_price : bar.low_price
      if state['pullback_at']
        return beyond && sign * (bar.close_price - peak) > 0
      end
      # Require a separate candle with a lower high (higher low for shorts):
      # a bar that contains both a new peak and a pullback has unknown ordering.
      if sign * (bar.close_price - state.fetch('previous_close').to_d) < 0 && sign * (favorable - peak) < 0
        state['pullback_at'] = bar.time.iso8601
      elsif sign * (favorable - peak) > 0
        state['peak'] = favorable.to_s
      end
      state['previous_close'] = bar.close_price.to_s
      false
    end
  end

  def self.entry_review(d, price, now:)
    unit = d['risk_unit']&.to_d
    base = { 'price' => price.to_s, 'reviewed_at' => now.iso8601,
      'wait_seconds' => (now - Time.iso8601(d.fetch('decision_at'))).round }
    return base.merge('accepted' => false, 'reason' => 'Недостаточно данных для оценки расстояния входа') unless unit&.positive?
    sign = d['direction'] == 'up' ? 1 : -1
    advance = sign * (price - d.fetch('decision_price').to_d) / unit
    risk = sign * (price - d.fetch('invalidation').to_d)
    levels = d.fetch('opposing_levels').select do |l|
      sign == 1 ? l.fetch('upper').to_d >= price : l.fetch('lower').to_d <= price
    end
    level = levels.min_by { |l| sign * (l.fetch(sign == 1 ? 'lower' : 'upper').to_d - price) }
    room = level && [sign * (level.fetch(sign == 1 ? 'lower' : 'upper').to_d - price), 0.to_d].max
    ratio = room && risk.positive? ? room / risk : nil
    limits = d.fetch('entry_thresholds')
    reason = if advance > limits.fetch('max_advance').to_d
      'Цена ушла слишком далеко после кандидата'
    elsif risk <= 0 || risk / unit > limits.fetch('max_risk').to_d
      'Слишком большое расстояние до отмены сценария'
    elsif ratio && ratio < limits.fetch('min_room_risk').to_d
      'Недостаточно места до сильного встречного уровня'
    end
    base.merge('accepted' => reason.nil?, 'reason' => reason || 'Фильтр входа пройден',
      'advance_ranges' => advance.to_f, 'risk_ranges' => (risk / unit).to_f,
      'risk_price' => risk.to_s, 'room_risk' => ratio&.to_f, 'opposing_level_id' => level && level['id'],
      'level_check' => level ? 'measured' : 'no_opposing_level')
  end
end
