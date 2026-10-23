class HintsController < ApplicationController
  CURRENT_KINDS = [DailyRetestResearch::KIND, DailySupportBounceResearch::KIND,
    IntradaySupportBounce::KIND, IntradayLevelBreakout::KIND].freeze

  def latest
    hints = MarketSignal.where(kind: CURRENT_KINDS)
    # Confirming an older candidate must advance the cursor too. Routine outcome
    # updates, cancellations and expiry are silent; updated_at cannot be used.
    latest = [hints.maximum(:created_at), hints.maximum(:confirmed_at)].compact.max
    response.headers['Cache-Control'] = 'no-store'
    render json: { latest_id: latest ? (latest.to_r * 1_000_000).to_i : 0 }
  end

  def index
    @version = params[:version].presence_in(%w[daily archive directional_v1 directional_v2 daily_retest_v1 daily_support_bounce_v1 intraday_support_bounce_v1 intraday_level_breakout_v1]) || 'daily'
    @archive = %w[archive directional_v1 directional_v2].include?(@version)
    @date = params[:date].present? ? Date.iso8601(params[:date]) : (@archive ? Date.current : nil)
    @status = DirectionalHints::LABELS.key?(params[:status]) ? params[:status] : nil
    scope = MarketSignal.where(kind: @archive ? DirectionalHints::KIND : CURRENT_KINDS)
    if @date
      from = Time.zone.local(@date.year, @date.month, @date.day)
      scope = scope.where(created_at: from...from + 1.day)
    end
    scope = scope.where(experiment: @version) unless %w[archive daily].include?(@version)
    if @archive
      @lifecycle_rows = HintLifecycle.statistics(date: @date)
    else
      @instruments = Instrument.watched.where(kind: %w[futures currency], breakout_enabled: true).in_display_order.select { |i| DailyRetestResearch.eligible?(i) }
      @bounce_pending = MarketSignal.where(kind: DailySupportBounceResearch::KIND, reversal_status: 'possible').group(:instrument_id).count
      @early_pending = MarketSignal.where(kind: IntradaySupportBounce::KIND, reversal_status: 'forming').group(:instrument_id).count
    end
    scope = scope.where(reversal_status: @status) if @status
    @page = [params[:page].to_i, 1].max
    @total = scope.count
    @hints = scope.includes(:instrument, :reaction, :confirmation_reaction).order(created_at: :desc, id: :desc).offset((@page - 1) * 50).limit(50)
    response.headers['Cache-Control'] = 'no-store'
  rescue Date::Error, TypeError
    render plain: 'Некорректная дата', status: :bad_request
  end
end
