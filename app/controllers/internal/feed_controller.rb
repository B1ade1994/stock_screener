module Internal
  class FeedController < ActionController::API
    before_action :authenticate
    def watchlist
      render json: { instruments: Instrument.watched.order(:id).limit(100).pluck(:uid) }
    end
    def ingest
      state = CollectorState.find_or_initialize_by(name: "market")
      state.update!(status: params[:status].to_s.first(80), message: params[:message].to_s.first(200), heartbeat_at: Time.current)
      Array(params[:instruments]).first(100).each do |raw|
        instrument = Instrument.watched.find_by(uid: raw[:uid])
        next unless instrument
        instrument.with_lock do
          Array(raw[:bars]).first(4).each do |item|
            time = Time.iso8601(item.fetch(:time))
            next if time < 10.minutes.ago || time > Time.current || time.sec != 0
            next unless item[:session].to_s.match?(/\A[0-9a-f-]{36}\z/)
            values = %i[buy sell unknown trades].to_h { |key| [key, Integer(item.fetch(key))] }
            next if values.values.any?(&:negative?)
            bar = instrument.market_minutes.find_or_initialize_by(time: time, session: item[:session])
            next if bar.persisted? && values[:trades] < bar.trades
            complete = item[:complete] == true && time + 95 <= Time.current
            next if bar.persisted? && values[:trades] == bar.trades && bar.complete == complete
            bar.assign_attributes(values.merge(complete: complete))
            bar.save!
            SignalEvaluator.volume(instrument, bar) if complete && params[:status] == "connected"
          end
          if raw[:price].present? && raw[:trade_time].present?
            time = Time.iso8601(raw[:trade_time])
            price = BigDecimal(raw[:price].to_s)
            if price.finite? && price.positive? && time <= 5.seconds.from_now && (!instrument.last_trade_at || time > instrument.last_trade_at)
              SignalEvaluator.crossings(instrument, price, time) if params[:status] == "connected"
              instrument.update!(last_price: price, last_trade_at: time)
            end
          end
        end
      end
      head :no_content
    end
    private
    def authenticate
      expected = ENV["INTERNAL_API_TOKEN"].to_s
      actual = request.headers["Authorization"].to_s.delete_prefix("Bearer ")
      head :unauthorized unless expected.present? && ActiveSupport::SecurityUtils.secure_compare(actual, expected)
    end
  end
end
