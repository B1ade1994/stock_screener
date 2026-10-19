class VolumeEpisode
  WINDOW = 10.minutes
  GROUPING_VERSION = 2

  def self.record(instrument:, bar:, details:)
    # Shared with stream ingestion and history refresh. Concurrent/retried snapshots
    # must not create a second episode or count the same minute twice.
    instrument.with_lock do
      time = bar.time + 60
      direction = if details[:buy] >= details[:volume] * 0.65
        "buy"
      elsif details[:sell] >= details[:volume] * 0.65
        "sell"
      else
        "mixed"
      end
      key = "volume:#{instrument.id}:#{bar.time.to_i}"
      existing = instrument.signals.find_by(event_key: key)
      return existing if existing
      recorded = instrument.signals.where(kind: 'volume').where('occurred_at > ? AND occurred_at <= ?', time - WINDOW, time)
        .where("details -> 'bursts' @> ?::jsonb", [{ time: time.iso8601 }].to_json).first
      return recorded if recorded

      quality = details[:quality]
      research = quality && quality[:enabled] && !quality[:passed] || false
      episode = instrument.signals.where(kind: "volume", research_only: research)
        .where("details ->> 'grouping_version' = ?", GROUPING_VERSION.to_s)
        .where("occurred_at > ? AND occurred_at <= ?", time - WINDOW, time).order(:occurred_at, :id).first
      episode ||= instrument.signals.new(kind: "volume", event_key: key, occurred_at: time, episode_direction: direction, research_only: research)
      if episode.new_record? && quality
        episode.details = details.stringify_keys.merge("decision" => quality.stringify_keys.merge("recorded_at" => Time.current.iso8601))
      end
      bursts = episode.details.fetch("bursts", []).deep_dup
      return episode if bursts.any? { |burst| burst["time"] == time.iso8601 }

      bursts << details.stringify_keys.merge("time" => time.iso8601, "recorded_at" => Time.current.iso8601, "session" => bar.session, "flow_direction" => direction)
      bursts.sort_by! { |burst| burst.fetch("time") }
      maximum = bursts.map { |burst| burst.fetch("ratio") }.max
      totals = %w[volume buy sell unknown].to_h { |field| [field, bursts.sum { |burst| burst.fetch(field) }] }
      price_open = bursts.first["open_price"]
      price_close = bursts.last["close_price"]
      price_direction = if price_open.present? && price_close.present?
        price_close.to_d > price_open.to_d ? "up" : price_close.to_d < price_open.to_d ? "down" : "flat"
      end
      episode.assign_attributes(
        last_occurred_at: [episode.last_occurred_at, time].compact.max,
        details: (episode.details.presence || details.stringify_keys).merge(
          "grouping_version" => GROUPING_VERSION,
          "bursts" => bursts, "max_ratio" => maximum, "burst_count" => bursts.size, "totals" => totals,
          "price_open" => price_open, "price_close" => price_close, "price_direction" => price_direction,
          "baseline_description" => "Медиана предыдущих 20 полных минут без разрывов"
        )
      )
      episode.title = episode.display_title
      fresh = episode.new_record?
      episode.save!
      VolumeFollowThrough.register(episode) if fresh
      episode
    end
  end
end
