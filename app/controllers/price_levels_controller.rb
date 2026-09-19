class PriceLevelsController < ApplicationController
  def create
    instrument = Instrument.find(params[:instrument_id])
    level = instrument.price_levels.new(params.require(:price_level).permit(:price, :side, :timeframe))
    level.source = "manual"
    if level.save
      redirect_to instrument_path(instrument), notice: "Уровень добавлен"
    else
      redirect_to instrument_path(instrument), alert: level.errors.full_messages.join(", ")
    end
  end
  def update
    instrument = Instrument.find(params[:instrument_id])
    level = instrument.price_levels.find(params[:id])
    visible = params.require(:price_level).permit(:chart_visible)[:chart_visible]
    return head :unprocessable_content unless [true, false, "true", "false"].include?(visible)

    level.update!(chart_visible: visible)
    render json: { id: level.id, chart_visible: level.chart_visible? }
  end

  def destroy
    instrument = Instrument.find(params[:instrument_id])
    level = instrument.price_levels.find(params[:id])
    level.source == "automatic" ? level.update!(active: false) : level.destroy!
    redirect_to instrument_path(instrument)
  end
end
