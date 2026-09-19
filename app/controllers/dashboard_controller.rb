class DashboardController < ApplicationController
  def index
    @tab = params[:tab] == "events" ? "events" : "stocks"
    @instruments = Instrument.in_display_order
    @signals = MarketSignal.includes(:instrument).order(occurred_at: :desc).limit(50) if @tab == "events"
    @collector = CollectorState.find_by(name: "market")
  end
end
