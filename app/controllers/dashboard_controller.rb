class DashboardController < ApplicationController
  def index
    @tab = params[:tab] == "events" ? "events" : "stocks"
    @instruments = Instrument.in_display_order
    if @tab == "events"
      @event_filter = %w[volume levels reversal].include?(params[:event_filter]) ? params[:event_filter] : "main"
      signals = MarketSignal.visible.includes(:instrument, :reaction, :confirmation_reaction).recent_activity
      signals = signals.where.not(kind: "volume") if @event_filter == "main"
      signals = signals.where(kind: "volume") if @event_filter == "volume"
      signals = signals.where.not(kind: %w[volume reversal]) if @event_filter == "levels"
      signals = signals.where(kind: 'reversal') if @event_filter == 'reversal'
      @signals = signals.limit(50)
    end
    @collector = CollectorState.find_by(name: "market")
  end
end
