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
  def destroy
    instrument = Instrument.find(params[:instrument_id])
    level = instrument.price_levels.find(params[:id])
    level.source == "automatic" ? level.update!(active: false) : level.destroy!
    redirect_to instrument_path(instrument)
  end
end
