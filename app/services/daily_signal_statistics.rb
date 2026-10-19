class DailySignalStatistics
  LABELS = { 'scenarios' => 'Сценарии: первое исходное событие',
    'volume' => 'Объём: все эпизоды', 'volume_visible' => 'Объём: в ленте', 'volume_suppressed' => 'Объём: отсеянные',
    'volume_trial' => 'Объём v2: движение ≥0,15%', 'volume_trial_rejected' => 'Объём v2: отсев исходной минуты',
    'volume_trial_confirmation' => 'Объём v2: после удержания',
    'context' => 'Эксперимент: длительный разворот', 'context_confirmation' => 'Эксперимент: подтверждение длительного',
    'structure' => 'Эксперимент: экстремум и ретест', 'structure_pullback' => 'Эксперимент: отскок, откат и пробой',
    'false_breakout' => 'Эксперимент: ложный пробой', 'crossing' => 'Пересечения уровней',
    'reversal' => 'Развороты: все кандидаты', 'confirmation' => 'Развороты: после подтверждения',
    'directional_hint' => 'Лонг/шорт v1: кандидаты', 'hint_confirmation' => 'Лонг/шорт v1: после подтверждения',
    'hint_v2' => 'Лонг/шорт v2: кандидаты', 'hint_v2_confirmation' => 'Лонг/шорт v2: после подтверждения',
    'levels' => 'Закрытия и развитие пробоя' }.freeze

  def self.call(date:, horizon:, full_only: true, non_overlapping: false, costs: SignalCosts.new, now: Time.current)
    from = Time.zone.local(date.year, date.month, date.day)
    period = from...from + 1.day
    initial = MarketSignal.where(created_at: period).where.not(kind: [DailyRetestResearch::KIND, DailySupportBounceResearch::KIND, IntradaySupportBounce::KIND]).includes(:reaction).to_a
    confirmed = MarketSignal.where(kind: %w[reversal directional_hint volume_followthrough], confirmed_at: period).includes(:confirmation_reaction).to_a
    legacy = initial.select { |signal| signal.kind == 'reversal' && signal.reversal_status == 'confirmed' && signal.confirmed_at.nil? }
    groups = initial.group_by do |signal|
      if signal.kind == VolumeFollowThrough::KIND
        signal.details['reason'].in?(%w[small_move missing_prices]) ? 'volume_trial_rejected' : 'volume_trial'
      elsif signal.kind == 'directional_hint' && signal.experiment == DirectionalHintResearch::EXPERIMENT
        'hint_v2'
      elsif signal.kind == 'reversal_structure'
        signal.experiment == TechnicalStudies::STRUCTURE ? 'structure_pullback' : 'structure'
      elsif signal.experiment == 'context_5m_v3'
        'context'
      else
        %w[volume crossing reversal directional_hint false_breakout].include?(signal.kind) ? signal.kind : 'levels'
      end
    end
    groups['volume_visible'], groups['volume_suppressed'] = groups.fetch('volume', []).partition { |s| !s.research_only? }
    groups['volume_trial_confirmation'] = confirmed.select { |s| s.kind == VolumeFollowThrough::KIND }
    groups['confirmation'] = (confirmed + legacy).reject { |s| s.experiment.present? }
    groups['context_confirmation'] = (confirmed + legacy).select { |s| s.experiment == 'context_5m_v3' }
    groups['hint_confirmation'] = confirmed.select { |s| s.kind == 'directional_hint' && s.experiment != DirectionalHintResearch::EXPERIMENT }
    groups['hint_v2_confirmation'] = confirmed.select { |s| s.kind == 'directional_hint' && s.experiment == DirectionalHintResearch::EXPERIMENT }
    scenarios = SignalScenarios.new(initial)
    groups['scenarios'] = scenarios.representatives.select { |s| period.cover?(s.created_at) }
    LABELS.map do |key, label|
      phase = %w[confirmation context_confirmation hint_confirmation hint_v2_confirmation volume_trial_confirmation].include?(key) ? 'confirmation' : 'initial'
      signals = groups.fetch(key, [])
      selected = non_overlapping ? without_overlap(signals, phase: phase, horizon: horizon) : signals
      summarize(selected, phase: phase, horizon: horizon, full_only: full_only, costs: costs, now: now)
        .merge(key: key, label: label, registered: signals.size, overlapping: signals.size - selected.size,
          linked_events: key == 'scenarios' ? initial.size - signals.size : 0,
          unresolved_links: key == 'scenarios' ? scenarios.unresolved_ids.size : 0)
    end
  end

  def self.direction(signal)
    case signal.kind
    when 'volume' then { 'buy' => 1, 'sell' => -1 }[signal.episode_direction]
    when 'reversal', 'reversal_structure', 'directional_hint', 'volume_followthrough', 'false_breakout' then { 'up' => 1, 'down' => -1 }[signal.details['direction']]
    when 'crossing' then { 'resistance' => 1, 'support' => -1 }[signal.details['side']]
    end
  end

  def self.summarize(signals, phase:, horizon:, full_only:, costs: SignalCosts.new, now: Time.current, direction_source: :signal)
    row = { total: signals.size, measured: 0, pending: 0, unavailable: 0, untracked: 0, partial: 0,
      excluded: 0, used: 0, directional: 0, positive: 0, negative: 0, flat: 0, undirected: 0, small: 0,
      meaningful_positive: 0, meaningful_negative: 0, neutral: 0, paired: 0, signal_matches: 0, baseline_matches: 0,
      full: 0, overdue: 0, recovering: 0, recovered: 0, net_positive: 0, excursion_measured: 0,
      quality_reasons: Hash.new(0) }
    values, magnitudes, net_values, favorable, adverse = [], [], [], [], []
    signals.each do |signal|
      reaction = phase == 'confirmation' ? signal.confirmation_reaction : signal.reaction
      unless reaction
        row[:untracked] += 1
        next
      end
      result = reaction.results[horizon.to_s]
      unless result
        row[:pending] += 1
        row[:overdue] += 1 if now >= reaction.reference_at + horizon.minutes + SignalReaction::SETTLE_DELAY
        next
      end
      incomplete = reaction.incomplete?(result, horizon)
      row[:quality_reasons][reaction.quality_code(result, horizon)] += 1 if incomplete
      row[:recovering] += 1 if incomplete && reaction.next_check_at && now < reaction.recovery_deadline(horizon)
      row[:recovered] += 1 if result['recovered_at'].present?
      unless result['status'] == 'measured'
        row[:unavailable] += 1
        next
      end
      row[:measured] += 1
      partial = result['candles'].to_i != horizon
      row[:partial] += 1 if partial
      row[:full] += 1 unless partial
      if partial && full_only
        row[:excluded] += 1
        next
      end
      change = result.fetch('change_percent').to_f
      row[:used] += 1
      magnitudes << change.abs
      row[:small] += 1 if change.abs < 0.2
      direction = direction_source == :technical ? { 'up' => 1, 'down' => -1 }[signal.details.dig('technical_context', 'direction')] : direction(signal)
      unless direction
        row[:undirected] += 1
        next
      end
      signed = change * direction
      row[signed >= 0.2 ? :meaningful_positive : signed <= -0.2 ? :meaningful_negative : :neutral] += 1
      values << signed
      net = signed - costs.round_trip_percent
      net_values << net
      row[:net_positive] += 1 if net.positive?
      if !partial && result['high_percent'].is_a?(Numeric) && result['low_percent'].is_a?(Numeric)
        marks = [0, result['high_percent'] * direction, result['low_percent'] * direction]
        favorable << marks.max
        adverse << marks.min
        row[:excursion_measured] += 1
      end
      row[:directional] += 1
      row[signed.positive? ? :positive : signed.negative? ? :negative : :flat] += 1
      baseline = reaction.baseline
      baseline_direction = baseline['status'] == 'measured' ? { 'up' => 1, 'down' => -1 }[baseline['direction']] : nil
      next unless baseline_direction
      row[:paired] += 1
      row[:signal_matches] += 1 if signed.positive?
      row[:baseline_matches] += 1 if (change * baseline_direction).positive?
    end
    wins = values.select(&:positive?)
    losses = values.select(&:negative?)
    net_losses = net_values.select(&:negative?).sum.abs
    row.merge(mean: average(values), median: median(values), absolute_mean: average(magnitudes),
      average_win: average(wins), average_loss: average(losses), net_mean: average(net_values),
      net_median: median(net_values), net_profit_factor: net_losses.positive? ? net_values.select(&:positive?).sum / net_losses : nil,
      favorable_mean: average(favorable), adverse_mean: average(adverse),
      full_coverage: row[:total].positive? ? 100.0 * row[:full] / row[:total] : nil)
  end

  def self.average(values) = values.any? ? values.sum / values.size : nil

  # Select before looking at future results; missing outcomes do not release a slot.
  def self.without_overlap(signals, phase:, horizon:)
    last = {}
    signals.sort_by { |s| [phase == 'confirmation' ? (s.confirmed_at || s.created_at) : s.created_at, s.id] }.select do |signal|
      reaction = phase == 'confirmation' ? signal.confirmation_reaction : signal.reaction
      at = reaction&.reference_at || (phase == 'confirmation' ? signal.confirmed_at : signal.created_at) || signal.created_at
      next false if last[signal.instrument_id] && at < last[signal.instrument_id] + horizon.minutes
      last[signal.instrument_id] = at
      true
    end
  end

  def self.median(values)
    return if values.empty?
    sorted = values.sort
    (sorted[(sorted.size - 1) / 2] + sorted[sorted.size / 2]) / 2.0
  end
end
