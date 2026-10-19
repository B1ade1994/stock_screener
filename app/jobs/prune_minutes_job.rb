class PruneMinutesJob < ApplicationJob
  def perform
    # Archive first; if it fails, do not destroy the source history.
    now = Time.current
    ArchiveMinuteVolumesJob.perform_now(now)
    MarketMinute.where('time < ?', now - 7.days).delete_all
    ReversalMinute.where('time < ?', now - 7.days).delete_all
  end
end
