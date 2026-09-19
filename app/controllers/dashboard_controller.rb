class DashboardController < ApplicationController
  def index
    @instruments = Instrument.in_display_order
    @signals = MarketSignal.includes(:instrument).order(occurred_at: :desc).limit(50)
    @collector = CollectorState.find_by(name: "market")
  end
end
