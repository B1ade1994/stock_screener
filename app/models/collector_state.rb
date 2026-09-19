class CollectorState < ApplicationRecord
  def live? = heartbeat_at.present? && heartbeat_at > 20.seconds.ago && status == "connected"
end
