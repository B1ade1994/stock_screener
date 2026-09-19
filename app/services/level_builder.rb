class LevelBuilder
  def self.call(instrument:, timeframe:, candles:)
    instrument.with_lock do
      candidates = Detectors::Levels.candidates(candles, timeframe: timeframe)
      existing = instrument.price_levels.where(source: "automatic", timeframe: timeframe).to_a
      matched = []
      candidates.each do |candidate|
        level = existing.reject { |row| matched.include?(row.id) }.select do |row|
          same_side = (row.assessment["origin_side"] || row.side) == candidate[:side]
          overlap = row.lower_bound <= candidate[:upper_price] && row.upper_bound >= candidate[:lower_price]
          same_side && overlap
        end.min_by { |row| (row.price.to_f - candidate[:price]).abs }
        if level
          matched << level.id
          next if level.status == "broken" # Freeze boundaries and evidence throughout an open scenario.
          hidden = !level.active? && level.status != "archived"
          role_changed = level.assessment["role_changed_at"].present?
          attrs = candidate.except(:side)
          attrs[:assessment] = candidate[:assessment].merge(level.assessment.slice("role_changed_at"))
          attrs[:status] = "confirmed" if role_changed
          level.update!(attrs.merge(active: !hidden, evaluated_at: candles.last&.time))
        else
          level = instrument.price_levels.create!(candidate.merge(timeframe: timeframe, source: "automatic", evaluated_at: candles.last&.time))
          matched << level.id
        end
      end
      existing.each do |level|
        next if matched.include?(level.id) || !level.active? || level.status == "broken"
        level.update!(active: false, status: "archived")
      end
    end
  end
end
