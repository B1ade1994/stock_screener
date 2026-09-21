class VolumeEpisode
  WINDOW = 10.minutes
  LABELS = { "buy" => "покупок", "sell" => "продаж", "mixed" => "смешанного потока" }.freeze

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

      episode = instrument.signals.where(kind: "volume", episode_direction: direction)
        .where("occurred_at > ? AND occurred_at <= ?", time - WINDOW, time).order(:occurred_at, :id).first
      episode ||= instrument.signals.new(kind: "volume", event_key: key, occurred_at: time, episode_direction: direction)
      bursts = episode.details.fetch("bursts", []).deep_dup
      return episode if bursts.any? { |burst| burst["time"] == time.iso8601 }

      bursts << details.stringify_keys.merge("time" => time.iso8601, "recorded_at" => Time.current.iso8601, "session" => bar.session)
      bursts.sort_by! { |burst| burst.fetch("time") }
      maximum = bursts.map { |burst| burst.fetch("ratio") }.max
      totals = %w[volume buy sell unknown].to_h { |field| [field, bursts.sum { |burst| burst.fetch(field) }] }
      price_open = bursts.first["open_price"]
      price_close = bursts.last["close_price"]
      price_direction = if price_open.present? && price_close.present?
        price_close.to_d > price_open.to_d ? "up" : price_close.to_d < price_open.to_d ? "down" : "flat"
      end
      episode.assign_attributes(
        title: "Эпизод #{LABELS.fetch(direction)} · объём до ×#{maximum}",
        last_occurred_at: [episode.last_occurred_at, time].compact.max,
        details: (episode.details.presence || details.stringify_keys).merge(
          "bursts" => bursts, "max_ratio" => maximum, "burst_count" => bursts.size, "totals" => totals,
          "price_open" => price_open, "price_close" => price_close, "price_direction" => price_direction,
          "baseline_description" => "Медиана предыдущих 20 полных минут без разрывов"
        )
      )
      episode.save!
      episode
    end
  end
end
