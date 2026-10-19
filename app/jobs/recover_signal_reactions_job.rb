class RecoverSignalReactionsJob < ApplicationJob
  queue_as :default
  limits_concurrency to: 1, key: 'recover-signal-reactions', duration: 10.minutes

  def perform
    now = Time.current
    # Reopen recent legacy gaps too; old observations are not fabricated/backfilled.
    SignalReaction.where(next_check_at: nil, reference_at: (now - 25.hours)..now).find_each do |reaction|
      reaction.with_lock do
        next if reaction.next_check_at
        reaction.schedule_next_check(now: now)
        reaction.save! if reaction.next_check_at
      end
    rescue ActiveRecord::RecordNotFound
      next
    end
  end
end
