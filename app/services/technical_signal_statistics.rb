class TechnicalSignalStatistics
  NEAR_LOCATIONS = %w[inside_zone near_support near_resistance near_both].freeze
  COHORTS = {
    'all' => 'Все с сохранённым ТА-контекстом', 'near' => 'У сильной зоны (≤0,5 дневного ATR)',
    'away' => 'Вдали от известных сильных зон', 'unknown_location' => 'Положение не оценено',
    'with_trend' => 'По дневному тренду', 'countertrend' => 'Против дневного тренда',
    'near_with_trend' => 'У зоны + по тренду', 'near_countertrend' => 'У зоны + против тренда'
  }.freeze
  VOLUME_COHORTS = { 'wick' => 'Свеча с длинной тенью', 'strong_close' => 'Закрытие у экстремума по направлению',
    'other_shape' => 'Другая форма свечи', 'unknown_shape' => 'Форма свечи не оценена' }.freeze

  def self.call(date:, horizon:, full_only: true, non_overlapping: true, costs: SignalCosts.new, now: Time.current)
    from = Time.zone.local(date.year, date.month, date.day)
    period = from...from + 1.day
    initial = MarketSignal.where(created_at: period).includes(:reaction).to_a
    confirmed = MarketSignal.where(kind: 'reversal', experiment: nil, confirmed_at: period).includes(:confirmation_reaction).to_a
    families = [
      ['reversal_confirmation', 'Резкий разворот: после подтверждения', confirmed, 'confirmation'],
      ['structure_v1', 'Экстремум + ретест: контроль', initial.select { |s| s.experiment == 'structure_v1' }, 'initial'],
      ['pullback', 'Отскок → откат → пробой: эксперимент', initial.select { |s| s.experiment == TechnicalStudies::STRUCTURE }, 'initial'],
      ['false_breakout', 'Ложный пробой: эксперимент', initial.select { |s| s.experiment == TechnicalStudies::FALSE_BREAKOUT }, 'initial'],
      ['volume', 'Объём в ленте: направление первой цены', initial.select { |s| s.kind == 'volume' && !s.research_only? }, 'initial']
    ]
    rows = []
    labeled = 0
    unlabeled = 0
    families.each do |key, label, signals, phase|
      eligible, missing = signals.partition { |s| s.details.dig('technical_context', 'version') == TechnicalContext::VERSION }
      labeled += eligible.size
      unlabeled += missing.size
      # Select before splitting by TA features so every subgroup is a subset of
      # the same prospective non-overlapping parent cohort.
      selected = non_overlapping ? DailySignalStatistics.without_overlap(eligible, phase: phase, horizon: horizon) : eligible
      cohorts = key == 'volume' ? COHORTS.merge(VOLUME_COHORTS) : COHORTS
      cohorts.each do |cohort, cohort_label|
        subset = selected.select { |s| member?(s.details.fetch('technical_context'), cohort) }
        next if subset.empty?
        stats = DailySignalStatistics.summarize(subset, phase: phase, horizon: horizon, full_only: full_only,
          costs: costs, now: now, direction_source: :technical)
        rows << stats.merge(family: key, family_label: label, cohort: cohort, cohort_label: cohort_label,
          family_total: eligible.size, family_selected: selected.size)
      end
    end
    { rows: rows, labeled: labeled, unlabeled: unlabeled, version: TechnicalContext::VERSION,
      primary_horizon: TechnicalContext::PRIMARY_HORIZON }
  end

  def self.member?(context, cohort)
    near = NEAR_LOCATIONS.include?(context['location'])
    case cohort
    when 'all' then true
    when 'near' then near
    when 'away' then context['location'] == 'away'
    when 'unknown_location' then context['location'] == 'unknown'
    when 'with_trend', 'countertrend' then context['alignment'] == cohort
    when 'near_with_trend' then near && context['alignment'] == 'with_trend'
    when 'near_countertrend' then near && context['alignment'] == 'countertrend'
    when 'wick' then %w[upper_wick lower_wick].include?(context.dig('candle', 'shape'))
    when 'strong_close' then %w[strong_up_close strong_down_close].include?(context.dig('candle', 'shape'))
    when 'other_shape' then %w[small_body mixed flat].include?(context.dig('candle', 'shape'))
    when 'unknown_shape' then context['candle'].nil?
    end
  end
end
