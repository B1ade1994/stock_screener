class RefreshSignalReactionsJob < ApplicationJob
  queue_as :default
  limits_concurrency to: 1, key: "signal-reactions", duration: 10.minutes

  def perform
    now = Time.current
    due = SignalReaction.due(now).includes(signal: :instrument).order(:next_check_at).limit(500).to_a
    due.group_by { |reaction| [reaction.signal.instrument_id, reaction.reference_at.utc.to_date] }.each_value do |reactions|
      refresh(reactions, now: now)
    end
  end

  private

  def refresh(reactions, now:)
    from = reactions.map(&:reference_at).min
    to = [reactions.map { |r| r.reference_at + 60.minutes }.max, now - SignalReaction::SETTLE_DELAY].min
    uid = reactions.first.signal.instrument.uid
    candles = []
    # The API accepts at most a day per 1-minute request. A group can straddle UTC midnight.
    while from < to
      finish = [from + 1.day, to].min
      candles.concat(TInvest::Client.new.minute_candles(uid, from: from, to: finish))
      from = finish
    end
    reactions.each { |reaction| SignalReactionRecorder.call(reaction: reaction, candles: candles, now: now) }
  rescue TInvest::Error => error
    reactions.each do |reaction|
      begin
        reaction.with_lock do
          next unless reaction.next_check_at
          if now >= reaction.reference_at + SignalReaction::MAX_RETRY_AGE
            reaction.unavailable!("Историю не удалось получить за 24 часа")
          else
            reaction.update!(last_error: error.message, next_check_at: now + 2.minutes)
          end
        end
      rescue ActiveRecord::RecordNotFound
        next
      end
    end
  end
end
