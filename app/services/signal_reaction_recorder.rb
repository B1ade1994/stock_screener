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
          reaction.unavailable!("Нет начальной биржевой свечи")
        else
          reaction.update!(next_check_at: now + 1.minute, last_error: nil)
        end
        return
      end

      results = reaction.results.deep_dup
      reaction.pending_horizons.each do |minutes|
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
        elsif now >= finish + SignalReaction::MISSING_GRACE
          results[minutes.to_s] = { "status" => "unavailable", "reason" => "Нет биржевой свечи в конце интервала" }
        end
      end
      pending = SignalReaction::HORIZONS.reject { |h| results.key?(h.to_s) }
      next_due = pending.map { |h| [reaction.reference_at + h.minutes + SignalReaction::SETTLE_DELAY, now + 1.minute].max }.min
      reaction.update!(reference_price: price, results: results, next_check_at: next_due, last_error: nil)
    end
  rescue ActiveRecord::RecordNotFound
    # The user may delete an event while its candles are being fetched.
    nil
  end
end
