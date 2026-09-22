class RefreshReversalHistoryJob < ApplicationJob
  limits_concurrency to: 1, key: ->(instrument_id = nil) { "reversal-history:#{instrument_id || 'dispatch'}" }, duration: 2.minutes

  def perform(instrument_id = nil)
    unless instrument_id
      Instrument.watched.where(reversal_enabled: true).find_each { |instrument| self.class.perform_later(instrument.id) }
      return
    end
    instrument = Instrument.watched.find_by(id: instrument_id, reversal_enabled: true)
    return unless instrument
    # A queued duplicate must not turn an API outage into a burst of requests.
    return if instrument.reversal_history_checked_at && instrument.reversal_history_checked_at > 50.seconds.ago
    ReversalHistory.refresh(instrument)
  rescue TInvest::Error => error
    instrument&.update!(reversal_history_checked_at: Time.current, reversal_history_error: error.message)
    Rails.logger.warn("reversal_history_failed instrument_id=#{instrument_id} error=#{error.class.name}")
  rescue ActiveRecord::RecordNotFound, ActiveRecord::InvalidForeignKey
    # The user may remove the instrument while its request is in flight.
    nil
  end
end
