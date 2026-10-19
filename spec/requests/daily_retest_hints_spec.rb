require 'rails_helper'

RSpec.describe 'Daily retest hints', type: :request do
  around { |example| travel_to(Time.zone.local(2026, 10, 7, 12)) { example.run } }
  it 'defaults to the daily experiment, keeps minute ideas in the archive and excludes shares from observation' do
    future = create_instrument(ticker: 'IMOEXF', kind: 'futures')
    share = create_instrument(ticker: 'SBER')
    legacy = share.signals.create!(kind: 'directional_hint', experiment: 'directional_v1', research_only: true,
      event_key: 'legacy', occurred_at: Time.current, title: 'Old', reversal_status: 'expired', details: {})
    hint = future.signals.create!(kind: DailyRetestResearch::KIND, experiment: DailyRetestResearch::EXPERIMENT,
      research_only: true, reversal_status: 'confirmed', confirmed_at: Time.current, occurred_at: Time.current,
      event_key: 'new', title: 'Дневной ретест · шорт', details: { direction: 'down', retest_at: 1.day.ago.iso8601, decision_price: '100', stop: '105', outcomes: {} })
    get hints_path
    expect(response).to have_http_status(:ok)
    page = Nokogiri::HTML(response.body)
    expect(page.css('[data-hint-id]').map { |el| el['data-hint-id'] }).to eq([hint.id.to_s])
    expect(page.at_css('.hint-watchlist').text).to include('IMOEXF')
    expect(page.at_css('.hint-watchlist').text).not_to include('SBER')
    expect(page.at_css('.signal-symbol')['class']).to include('price-down')
    expect(page.text).to include('Архив минутных идей', 'начавшейся после регистрации')
    expect(hint.reactions).to be_empty
    get latest_signals_path
    expect(response.parsed_body['latest_id']).to eq(0)
    get hints_path(date: 'incorrect')
    expect(response).to have_http_status(:bad_request)
  end
end
