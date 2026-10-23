class RefreshIntradayBreakoutsJob < ApplicationJob
  limits_concurrency to: 1, key: ->(instrument_id = nil) { "intraday-breakout:#{instrument_id || 'dispatch'}" }, duration: 2.minutes

  def perform(instrument_id = nil)
    unless instrument_id
      Instrument.where(kind: %w[futures currency]).find_each { |instrument| self.class.perform_later(instrument.id) }
      return
    end
    instrument = Instrument.find_by(id: instrument_id)
    IntradayLevelBreakout.call(instrument) if instrument
  rescue TInvest::Error => error
    Rails.logger.warn("intraday_breakout_failed instrument_id=#{instrument_id} error=#{error.class.name}")
  rescue ActiveRecord::RecordNotFound, ActiveRecord::InvalidForeignKey
    nil
  end
end
