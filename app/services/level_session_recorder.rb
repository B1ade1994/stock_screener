class LevelSessionRecorder
  HORIZONS = [1, 3, 5].freeze
  KINDS = %w[crossing confirmed retest held_breakout].freeze

  def self.call(instrument:, now: Time.current)
    signals = instrument.signals.where(kind: KINDS).includes(:reaction)
    days = instrument.candles.where(timeframe: 'day', data_source: 't_invest')
      .where('time < ?', now.in_time_zone.beginning_of_day).order(:time).to_a
    signals.find_each do |signal|
      reaction = signal.reaction
      next unless reaction && HORIZONS.any? { |h| !reaction.session_results.key?(h.to_s) }
      reaction.with_lock do
        results = reaction.session_results.deep_dup
        unless reaction.reference_price&.positive?
          if reaction.next_check_at.nil?
            HORIZONS.each { |h| results[h.to_s] ||= { 'status' => 'unavailable', 'reason' => 'Нет цены начала отсчёта' } }
            reaction.update!(session_results: results)
          end
          next
        end
        candles = days.select { |c| c.time.in_time_zone.to_date >= reaction.reference_at.in_time_zone.to_date }
        HORIZONS.each do |h|
          next if results.key?(h.to_s) || !candles[h - 1]
          candle = candles[h - 1]
          results[h.to_s] = { 'status' => 'measured', 'change_percent' => ((candle.close / reaction.reference_price - 1) * 100).round(6).to_f,
            'price' => candle.close.to_s, 'candle_time' => candle.time.iso8601, 'measured_at' => now.iso8601 }
        end
        reaction.update!(session_results: results)
      end
    rescue ActiveRecord::RecordNotFound
      next
    end
  end

  def self.statistics(date)
    signals = MarketSignal.where(kind: KINDS, created_at: date.in_time_zone.all_day).includes(:reaction).to_a
    HORIZONS.map do |h|
      counts = { horizon: h, total: signals.size, measured: 0, pending: 0, unavailable: 0, positive: 0, negative: 0, flat: 0 }
      values = []
      signals.each do |signal|
        result = signal.reaction&.session_results&.[](h.to_s)
        if !result
          counts[:pending] += 1
        elsif result['status'] != 'measured'
          counts[:unavailable] += 1
        else
          counts[:measured] += 1
          sign = { 'support' => -1, 'resistance' => 1 }[signal.details['side']]
          next unless sign
          signed = result.fetch('change_percent') * sign
          values << signed
          counts[signed.positive? ? :positive : signed.negative? ? :negative : :flat] += 1
        end
      end
      counts.merge(mean: values.any? ? values.sum / values.size : nil)
    end
  end
end
