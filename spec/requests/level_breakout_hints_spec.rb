require 'rails_helper'

RSpec.describe 'Level breakout hints', type: :request do
  around { |example| travel_to(Time.zone.local(2026, 10, 23, 12)) { example.run } }

  def hint(instrument, direction)
    instrument.signals.create!(kind: IntradayLevelBreakout::KIND, experiment: IntradayLevelBreakout::EXPERIMENT,
      research_only: true, reversal_status: 'confirmed', confirmed_at: Time.current,
      event_key: "breakout-#{direction}", occurred_at: Time.current, title: "Пробой без ретеста · #{direction == 'up' ? 'лонг' : 'шорт'}",
      details: { 'direction' => direction, 'decision_price' => '101', 'stop' => direction == 'up' ? '98' : '104',
        'target' => direction == 'up' ? '110' : '90', 'room_risk' => 3,
        'status_reason' => 'Две завершённые минуты за зоной',
        'setup' => { 'frame' => 'day', 'lower' => '100', 'upper' => '102',
          'target_zone' => { 'frame' => 'week', 'lower' => '88', 'upper' => '90' } },
        'early_evidence' => [4, 3, 2].map { |n| { 'time' => n.minutes.ago.iso8601, 'close' => '101' } } })
  end

  it 'shows both directions, preserves the filter, notifies and measures them as a separate family' do
    instrument = create_instrument(kind: 'futures')
    short = hint(instrument, 'down')
    travel 1.second
    long = hint(instrument, 'up')
    get hints_path(version: IntradayLevelBreakout::EXPERIMENT)
    expect(response).to have_http_status(:ok)
    page = Nokogiri::HTML(response.body)
    expect(page.css('[data-hint-id]').map { |n| n['data-hint-id'] }).to eq([long.id.to_s, short.id.to_s])
    expect(page.text).to include('Подтверждён по минутному правилу', 'следующего сопротивления', 'следующей поддержки', 'Стоп:')
    expect(page.text).not_to include('Цель 2R', 'Закрытие ретеста')
    expect(page.at_css('#directional-hints')['data-refresh-url-value']).to include('version=intraday_level_breakout_v1')
    get latest_hints_path
    cursor = response.parsed_body['latest_id']
    expect(cursor).to eq((long.created_at.to_r * 1_000_000).to_i)
    travel 1.second
    long.update!(details: long.details.merge('note' => 'outcome updated'))
    get latest_hints_path
    expect(response.parsed_body['latest_id']).to eq(cursor)
    get hints_path(version: DailyRetestResearch::EXPERIMENT)
    expect(response.body).not_to include("data-hint-id=\"#{long.id}\"")
    stats = DailySignalStatistics.call(date: Date.current, horizon: 5)
    expect(stats.find { |row| row[:key] == 'level_breakout' }[:total]).to eq(2)
    expect(stats.find { |row| row[:key] == 'levels' }[:total]).to eq(0)
    expect(DailySignalStatistics.direction(short)).to eq(-1)
    expect(DailySignalStatistics.direction(long)).to eq(1)
  end
end
