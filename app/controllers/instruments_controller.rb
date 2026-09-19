class InstrumentsController < ApplicationController
  rescue_from TInvest::Error, with: :api_error
  def search
    @query = params[:q].to_s.strip.first(80)
    @results = @query.present? ? TInvest::Client.new.search(@query) : []
  end
  def create
    if Instrument.count >= 100
      redirect_to root_path, alert: "В первой версии поддерживается до 100 инструментов."; return
    end
    instrument = Instrument.create!(TInvest::Client.new.instrument(params.require(:uid)))
    RefreshHistoryJob.perform_later(instrument.id)
    redirect_to instrument_path(instrument), notice: "Инструмент добавлен. Загружаем дневную и недельную историю."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to root_path, alert: e.record.errors.full_messages.join(", ")
  end
  def show
    @instrument = Instrument.find(params[:id])
    @levels = @instrument.price_levels.active.order(:timeframe, :price)
    @level_strength = LevelStrength.new(@levels)
    @signals = @instrument.signals.order(occurred_at: :desc).limit(30)
    @timeframe = %w[day week].include?(params[:timeframe]) ? params[:timeframe] : "day"
    @candles = @instrument.candles.where(timeframe: @timeframe).order(:time).to_a
    @chart_start_index = 0
    if @timeframe == "day" && @candles.any?
      start_date = @candles.last.time.to_date << 2
      @chart_start_index = @candles.index { |candle| candle.time.to_date >= start_date } || 0
    end
    @ema_series = (@timeframe == "week" ? [20, 40] : [20, 50, 200]).to_h { |period| [period, MarketIndicators.ema(@candles, period)] }
    @trend = MarketIndicators.context(@candles, @timeframe)
  end
  def quote
    instrument = Instrument.find(params[:id])
    response.headers["Cache-Control"] = "no-store"
    render json: { price: instrument.last_price, traded_at: instrument.last_trade_at&.iso8601 }
  end

  def update
    @instrument = Instrument.find(params[:id])
    saved = @instrument.update(params.require(:instrument).permit(:enabled, :volume_enabled, :breakout_enabled, :volume_multiplier, :minimum_volume))
    @save_error = @instrument.errors.full_messages.join(", ") unless saved

    if request.format.turbo_stream? && request.headers["Turbo-Frame"] == "dashboard"
      @instrument.reload unless saved
      @watched_count = Instrument.watched.count
      render :update, status: saved ? :ok : :unprocessable_entity
    elsif saved
      redirect_back fallback_location: root_path, notice: "Настройки сохранены"
    else
      redirect_back fallback_location: root_path, alert: @save_error
    end
  end

  def move
    return head :bad_request unless %w[before after].include?(params[:placement])

    Instrument.find(params[:id]).move_in_list!(target_id: params.require(:target_id), placement: params[:placement])
    head :no_content
  end

  def destroy
    Instrument.find(params[:id]).destroy!
    redirect_to root_path, notice: "Инструмент удалён", status: :see_other
  end
  def refresh
    RefreshHistoryJob.perform_later(params[:id])
    redirect_to instrument_path(params[:id]), notice: "Обновление истории поставлено в очередь"
  end
  private
  def api_error(error)
    redirect_to root_path, alert: error.message
  end
end
