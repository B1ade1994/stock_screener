class HintsController < ApplicationController
  def latest
    hints = MarketSignal.where(kind: [DailyRetestResearch::KIND, DailySupportBounceResearch::KIND, IntradaySupportBounce::KIND])
    # Confirming an older candidate must advance the cursor too. Routine outcome
    # updates, cancellations and expiry are silent; updated_at cannot be used.
    latest = [hints.maximum(:created_at), hints.maximum(:confirmed_at)].compact.max
    response.headers['Cache-Control'] = 'no-store'
    render json: { latest_id: latest ? (latest.to_r * 1_000_000).to_i : 0 }
  end

  def index
    @version = params[:version].presence_in(%w[daily archive directional_v1 directional_v2 daily_retest_v1 daily_support_bounce_v1 intraday_support_bounce_v1]) || 'daily'
    @archive = %w[archive directional_v1 directional_v2].include?(@version)
    @date = params[:date].present? ? Date.iso8601(params[:date]) : (@archive ? Date.current : nil)
    @status = DirectionalHints::LABELS.key?(params[:status]) ? params[:status] : nil
    scope = MarketSignal.where(kind: @archive ? DirectionalHints::KIND : [DailyRetestResearch::KIND, DailySupportBounceResearch::KIND, IntradaySupportBounce::KIND])
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
      rows = scope.to_a
      @daily_results = [[DailyRetestResearch::EXPERIMENT, 'Пробой + ретест'],
        [DailySupportBounceResearch::EXPERIMENT, 'Отскок от поддержки'],
        [IntradaySupportBounce::EXPERIMENT, 'Ранний отскок · текущий день']].filter_map do |experiment, label|
        next if @version != 'daily' && @version != experiment
        family = rows.select { |s| s.experiment == experiment }
        confirmed = family.select(&:confirmed_at)
        { label: label, candidates: family.count { |s| s.reversal_status.in?(%w[possible forming]) }, results: DailyRetestOutcome::HORIZONS.map do |horizon|
          results = confirmed.filter_map { |s| s.details.dig('outcomes', horizon.to_s) }
          measured = results.select { |r| r['status'] == 'measured' }
          { horizon: horizon, total: confirmed.size, measured: measured.size,
            mean: measured.any? ? measured.sum { |r| r['trade_low'] } / measured.size : nil,
            positive: measured.count { |r| r['trade_low'].positive? }, ambiguous: measured.count { |r| r['ambiguous'] } }
        end }
      end
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
