# Relative evidence strength within one instrument, timeframe and scoring version.
# This describes ranking, not a calibrated probability of holding or breaking.
class LevelStrength
  Result = Data.define(:label, :grade, :explanation)

  def initialize(levels)
    @groups = levels.select { |level| comparable?(level) }.group_by { |level| group_key(level) }
  end

  def call(level)
    return Result.new("Без оценки", nil, "Ручному уровню автоматические баллы не назначаются.") if level.source == "manual"
    return Result.new("Неактивен", nil, "Уровень исключён из текущего сравнения.") unless level.active?
    return Result.new("Предварительная", nil, "Нужен повторный независимый подход цены. Высокий объём одного касания ещё не подтверждает силу зоны.") if level.status == "candidate"
    return Result.new("Пробой", nil, "Идёт проверка пробоя. Зафиксированные до пробоя баллы не участвуют в текущем сравнении силы.") if level.status == "broken"
    return Result.new("Нет оценки", nil, "Нужны актуальные баллы по ATR и минимум два подтверждённых касания; обновите историю.") unless comparable?(level)

    scores = @groups.fetch(group_key(level), []).map { |peer| score(peer) }
    period = level.timeframe == "week" ? "1W" : "1D"
    if scores.size < 3
      return Result.new("Мало уровней", nil, "Для относительной оценки нужны минимум 3 подтверждённые зоны #{period} этой бумаги; сейчас #{scores.size}. Баллы доступны отдельно.")
    end
    value = score(level)
    # Average rank gives equal scores equal grades; a fully tied group is medium.
    position = (scores.count { |s| s < value } + (scores.count(value) - 1) / 2.0) / (scores.size - 1)
    grade = position < 1.0 / 3 ? 1 : position > 2.0 / 3 ? 3 : 2
    label = { 1 => "Низкая", 2 => "Средняя", 3 => "Высокая" }.fetch(grade)
    Result.new(label, grade, "Относительная сила среди #{scores.size} подтверждённых зон #{period} этой бумаги: касания, объём, отскок в ATR и давность. Не вероятность удержания или пробоя.")
  end

  private

  def group_key(level)
    [level.instrument_id, level.timeframe, level.assessment["version"]]
  end

  def score(level)
    value = level.assessment["score"]
    value.is_a?(Numeric) && value.to_f.finite? && value >= 0 ? value.to_f : nil
  end

  def comparable?(level)
    level.source == "automatic" && level.active? && level.status == "confirmed" &&
      level.touches >= 2 && level.assessment["version"] == Detectors::Levels::VERSION && !score(level).nil?
  end
end
