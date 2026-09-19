class SignalsController < ApplicationController
  def destroy
    signal = MarketSignal.find(params[:id])
    signal.destroy!
    respond_to do |format|
      format.turbo_stream { render turbo_stream: turbo_stream.remove(signal) }
      format.html { redirect_back fallback_location: root_path(tab: "events"), status: :see_other }
    end
  end

  def latest
    response.headers["Cache-Control"] = "no-store"
    render json: { latest_id: MarketSignal.maximum(:id) || 0 }
  end
end
