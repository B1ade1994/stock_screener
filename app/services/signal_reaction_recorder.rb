class SignalReactionRecorder
  def self.call(reaction:, candles:, now: Time.current)
    return unless reaction.persisted?
    reaction.with_lock do
      return unless reaction.next_check_at
      # Only closed exchange candles; never substitute a quote from another minute.
      book = candles.select { |c| c.fetch(:time) + 60 <= now }.index_by { |c| c.fetch(:time).to_i }
      first = book[reaction.reference_at.to_i]
      price = reaction.reference_price || first&.fetch(:open)
      unless price&.positive?
        if now >= reaction.reference_at + SignalReaction::MISSING_GRACE
          # Absence alone cannot distinguish no trades, a closed session or an API gap.
          results = reaction.results.deep_dup
          reaction.refreshable_horizons(now: now).each do |minutes|
            next if now < reaction.reference_at + minutes.minutes + SignalReaction::SETTLE_DELAY
            results[minutes.to_s] = { 'status' => 'unavailable', 'reason' => 'Нет начальной биржевой свечи',
              'quality_code' => 'missing_start', 'checked_at' => now.iso8601 }
          end
          reaction.results = results
          reaction.schedule_next_check(now: now)
          reaction.last_error = nil
          reaction.save!
        else
          reaction.update!(next_check_at: now + 1.minute, last_error: nil)
        end
        return
      end

      baseline = reaction.baseline.presence || preceding_trend(book, reaction.reference_at)
      results = reaction.results.deep_dup
      reaction.refreshable_horizons(now: now).each do |minutes|
        finish = reaction.reference_at + minutes.minutes
        next if now < finish + SignalReaction::SETTLE_DELAY
        last = book[(finish - 60).to_i]
        if last
          window = book.values.select { |c| c.fetch(:time) >= reaction.reference_at && c.fetch(:time) < finish }
          change = ->(value) { ((value.to_d / price - 1) * 100).round(6).to_f }
          results[minutes.to_s] = {
            "status" => "measured", "price" => last.fetch(:close).to_s,
            "change_percent" => change.call(last.fetch(:close)),
            "high_percent" => change.call(window.map { |c| c.fetch(:high) }.max),
            "low_percent" => change.call(window.map { |c| c.fetch(:low) }.min),
            "candles" => window.size, "measured_at" => now.iso8601
          }
          if window.size != minutes
            missing = (0...minutes).filter_map { |offset| (reaction.reference_at + offset.minutes).iso8601 unless book.key?((reaction.reference_at + offset.minutes).to_i) }
            results[minutes.to_s].merge!('quality_code' => 'missing_minutes', 'missing_count' => missing.size,
              'missing_at' => missing)
          end
          # A smaller later response must not degrade an already observed window.
          previous = reaction.results[minutes.to_s]
          results[minutes.to_s] = previous if previous && previous['status'] == 'measured' && previous['candles'].to_i >= window.size
          if previous && reaction.incomplete?(previous, minutes) && window.size == minutes
            results[minutes.to_s]['recovered_at'] = now.iso8601
          end
        elsif now >= finish + SignalReaction::MISSING_GRACE
          previous = reaction.results[minutes.to_s]
          next if previous && previous['status'] == 'measured'
          results[minutes.to_s] = { "status" => "unavailable", "reason" => "Нет биржевой свечи в конце интервала",
            'quality_code' => 'missing_end', 'checked_at' => now.iso8601 }
        end
      end
      reaction.assign_attributes(reference_price: price, results: results, baseline: baseline, last_error: nil)
      reaction.schedule_next_check(now: now)
      reaction.save!
    end
  rescue ActiveRecord::RecordNotFound
    # The user may delete an event while its candles are being fetched.
    nil
  end

  def self.preceding_trend(book, reference)
    preceding = (1..5).map { |offset| book[(reference - offset.minutes).to_i] }.reverse
    return { 'status' => 'unavailable', 'reason' => 'Нет пяти непрерывных свечей до отсчёта' } unless preceding.all?
    opening = preceding.first.fetch(:open).to_d
    closing = preceding.last.fetch(:close).to_d
    return { 'status' => 'unavailable', 'reason' => 'Некорректная цена до отсчёта' } unless opening.positive? && closing.positive?
    { 'status' => 'measured', 'direction' => closing > opening ? 'up' : closing < opening ? 'down' : 'flat',
      'change_percent' => ((closing / opening - 1) * 100).round(6).to_f }
  end

end
