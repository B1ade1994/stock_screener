class ExpireReversalsJob < ApplicationJob
  def perform
    # Settle time allows the last eligible complete minute to reach ingestion.
    MarketSignal.where(kind: 'reversal', reversal_status: 'possible')
      .where('occurred_at < ?', Time.current - ReversalTracker::CONFIRMATION_WINDOW - 2.minutes).find_each do |signal|
      signal.instrument.with_lock do
        signal.reload
        next unless signal.reversal_status == 'possible'
        ReversalTracker.finish(signal, 'expired', 'Нет подтверждения за 10 минут; поступление данных могло прерваться', Time.current)
      end
    rescue ActiveRecord::RecordNotFound
      # The user can delete events/instruments while the job is running.
      next
    end
  end
end
