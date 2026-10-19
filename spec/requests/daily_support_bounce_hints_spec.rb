require 'rails_helper'

RSpec.describe 'Daily support bounce hints', type: :request do
  around { |example| travel_to(Time.zone.local(2026, 10, 16, 12)) { example.run } }
  it 'shows candidates, countertrend, EMA evidence and separated results while preserving filters on refresh' do
    instrument = create_instrument(kind: 'currency', ticker: 'GLDRUB_TOM', class_code: 'CETS')
    hint = instrument.signals.create!(kind: DailySupportBounceResearch::KIND, experiment: DailySupportBounceResearch::EXPERIMENT,
      research_only: true, reversal_status: 'possible', event_key: 'bounce', occurred_at: Time.current,
      title: 'Отскок от поддержки · кандидат в лонг', details: { direction: 'up', stop: '10969', decision_price: '10993.5',
        status_reason: 'Ждём дневное подтверждение', touch_context: { direction: 'down' },
        setup: { lower: '10996', upper: '11618', frame: 'week', touch_at: '2026-10-14T00:00:00Z', extreme: '10990.5',
          weekly_ema40: 11071.6, near_weekly_ema40: true } })
    get hints_path
    page = Nokogiri::HTML(response.body)
    expect(response).to have_http_status(:ok)
    expect(page.css('[data-hint-id]').map { |n| n['data-hint-id'] }).to eq([hint.id.to_s])
    expect(page.text).to include('Контртренд', 'EMA40', 'Ожидает подтверждения', 'Пробой + ретест', 'Отскок от поддержки')
    expect(page.text).not_to include('Условный вход:')
    get hints_path(version: DailySupportBounceResearch::EXPERIMENT, status: 'possible')
    expect(Nokogiri::HTML(response.body).at_css('#directional-hints')['data-refresh-url-value']).to include('version=daily_support_bounce_v1', 'status=possible')
    hint.update!(reversal_status: 'confirmed', confirmed_at: Time.current, details: hint.details.merge(
      'confirmation_at' => '2026-10-15T00:00:00Z', 'outcomes' => { '1' => { 'status' => 'measured', 'trade_low' => 1.0, 'trade_high' => 1.0,
        'price_change' => 1.0, 'exit_reason' => 'timeout', 'ambiguous' => false } }))
    get hints_path(version: DailySupportBounceResearch::EXPERIMENT)
    expect(response).to have_http_status(:ok)
    expect(Nokogiri::HTML(response.body).text).to include('Ожидаем первую завершённую дневную свечу', '+1.00%')
    get hints_path(version: DailyRetestResearch::EXPERIMENT)
    expect(response.body).not_to include("data-hint-id=\"#{hint.id}\"")
    get latest_signals_path
    expect(response.parsed_body['latest_id']).to eq(0)
  end
end
