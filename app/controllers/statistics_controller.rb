class StatisticsController < ApplicationController
  def index
    @date = params[:date].present? ? Date.iso8601(params[:date]) : Date.current
    @horizon = SignalReaction::HORIZONS.include?(params[:horizon].to_i) ? params[:horizon].to_i : TechnicalContext::PRIMARY_HORIZON
    @full_only = params[:full] != '0'
    @non_overlapping = params[:independent] != '0'
    @costs = SignalCosts.from_params(params)
    @snapshot_at = Time.current
    @rows = DailySignalStatistics.call(date: @date, horizon: @horizon, full_only: @full_only, non_overlapping: @non_overlapping, costs: @costs, now: @snapshot_at)
    @technical = TechnicalSignalStatistics.call(date: @date, horizon: @horizon, full_only: @full_only,
      non_overlapping: @non_overlapping, costs: @costs, now: @snapshot_at)
    @sessions = LevelSessionRecorder.statistics(@date)
    response.headers['Cache-Control'] = 'no-store'
  rescue ArgumentError, TypeError
    render plain: 'Некорректная дата или издержки (допустимы числа от 0 до 100%)', status: :bad_request
  end
end
