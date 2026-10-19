require 'rails_helper'

RSpec.describe 'Intraday bounce hints', type: :request do
  around { |example| travel_to(Time.zone.local(2026, 10, 19, 12)) { example.run } }

  it 'shows forming ideas separately, preserves filters, notifies once and excludes them from minute results' do
    instrument = create_instrument(kind: 'futures')
    signal = instrument.signals.create!(kind: IntradaySupportBounce::KIND, experiment: IntradaySupportBounce::EXPERIMENT,
      research_only: true, reversal_status: 'forming', event_key: 'early-bounce', occurred_at: Time.current,
      title: 'Ранний отскок от поддержки · кандидат в лонг', details: { 'direction' => 'up', 'stop' => '99.3',
        'early_price' => '102', 'decision_price' => '102', 'confirmation_boundary' => '100.2',
        'setup' => { 'frame' => 'day', 'lower' => '100', 'upper' => '102', 'extreme' => '99.5', 'touch_at' => Time.current.utc.beginning_of_day.iso8601 },
        'early_evidence' => [4, 3, 2].map { |n| { 'time' => n.minutes.ago.iso8601, 'close' => '102' } } })
    get hints_path(version: IntradaySupportBounce::EXPERIMENT, status: 'forming')
    expect(response).to have_http_status(:ok)
    page = Nokogiri::HTML(response.body)
    expect(page.css('[data-hint-id]').map { |n| n['data-hint-id'] }).to eq([signal.id.to_s])
    expect(page.at_css('#directional-hints')['data-refresh-url-value']).to include('status=forming', 'version=intraday_support_bounce_v1')
    expect(page.text).to include('Формируется сегодня', 'Ранний эксперимент', 'Ранний отскок · текущий день', 'Не более одной ранней идеи')
    expect(page.text).not_to include('Условный вход:')
    expect(signal.reactions).to be_empty
    expect(DailySignalStatistics.call(date: Date.current, horizon: 5).sum { |row| row[:total] }).to eq(0)

    get latest_hints_path
    created_cursor = response.parsed_body['latest_id']
    expect(created_cursor).to be_positive
    travel 1.second
    signal.update!(reversal_status: 'cancelled')
    get latest_hints_path
    expect(response.parsed_body['latest_id']).to eq(created_cursor)
    get hints_path(status: 'forming')
    expect(response.body).not_to include("data-hint-id=\"#{signal.id}\"")
    get hints_path(version: DailySupportBounceResearch::EXPERIMENT)
    expect(response.body).not_to include("data-hint-id=\"#{signal.id}\"")
    get root_path(tab: 'events')
    expect(response.body).not_to include("data-hint-id=\"#{signal.id}\"")
  end
end
