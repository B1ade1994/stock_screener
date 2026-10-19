require 'rails_helper'
RSpec.describe 'Directional research hints', type: :request do
  around { |e| travel_to(Time.zone.local(2026,9,29,16)) { e.run } }
  it 'shows no-signal/data states, frozen conditions, partial measurements, and never sounds a hint' do
    instrument = create_instrument(reversal_enabled: true)
    get hints_path(version: 'archive')
    expect(response).to have_http_status(:ok)
    bar = instrument.reversal_minutes.create!(time: 2.minutes.ago, open_price: 100, close_price: 100, high_price: 100.1, low_price: 99.9, volume: 100, data_source: 't_invest')
    get hints_path(version: 'archive')
    hint = DirectionalHints.create(instrument,bar,{direction:'up',extreme:98,volatility:1,rebound_boundary:100},key:'test',basis:'Резкий импульс',now:Time.current)
    hint.reaction.update!(results: {'15'=>{status:'measured',price:'100.1',change_percent:0.1,high_percent:0.2,low_percent:-0.1,candles:13}})
    get hints_path(version: 'archive')
    page = Nokogiri::HTML(response.body)
    expect(page.at_css('turbo-frame#directional-hints')).to be_present
    expect(page.at_css("a[href='#{hints_path}'][aria-current=page]")).to be_present
    expect(page.text).to include('Кандидат в лонг','Ожидает подтверждения','Резкий импульс','неполные данные','13/15')
    expect(page.css('.reaction-outcome').size).to eq(4)
    get hints_path(version: 'directional_v1')
    expect(Nokogiri::HTML(response.body).css('.reaction-outcome').size).to eq(2)
    get latest_signals_path
    expect(response.parsed_body['latest_id']).to eq(0)
    get root_path(tab:'events')
    expect(response.body).not_to include('data-hint-id')
    get hints_path(version: 'archive', status:'cancelled')
    expect(response.body).not_to include("data-hint-id=\"#{hint.id}\"")
    get hints_path(date:'bad')
    expect(response).to have_http_status(:bad_request)
  end
  it 'renders missed entries, lifecycle results and preserves the version when refreshing' do
    instrument = create_instrument(reversal_enabled: true)
    b = instrument.reversal_minutes.create!(time: 2.minutes.ago, open_price: 100, close_price: 100,
      high_price: 100.1, low_price: 99.9, volume: 100, data_source: 't_invest')
    control = DirectionalHints.create(instrument, b, { direction: 'up', extreme: 98, volatility: 1, rebound_boundary: 100 },
      key: 'render', basis: 'Test', now: Time.current)
    hint = instrument.signals.find_by!(experiment: 'directional_v2')
    hint.update!(reversal_status: 'missed', details: hint.details.merge('monitoring' => false,
      'entry_review' => { 'reason' => 'Цена ушла слишком далеко после кандидата', 'wait_seconds' => 120,
        'advance_ranges' => 2.1, 'risk_ranges' => 4.2, 'level_check' => 'no_opposing_level' }))
    d = control.details.deep_dup
    HintLifecycle.start(d, now: Time.current)
    HintLifecycle.close(d, now: Time.current + 2.minutes, reason: 'Отмена')
    d['lifecycle'].merge!('status' => 'measured', 'entry_price' => '100', 'exit_price' => '99',
      'signed_change_percent' => -1.0, 'adverse_percent' => -2.0, 'favorable_percent' => 0.5)
    control.update!(reversal_status: 'confirmed', confirmed_at: Time.current, details: d)
    get hints_path(version: 'archive')
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('Движение подтверждено, вход пропущен', 'Условный выход:',
      'максимальное отклонение против идеи', 'цель не рассчитана')
    get hints_path(version: 'directional_v2', status: 'missed')
    page = Nokogiri::HTML(response.body)
    expect(page.css('[data-hint-id]').map { |node| node['data-hint-id'] }).to eq([hint.id.to_s])
    expect(page.at_css('#directional-hints')['data-refresh-url-value']).to include('version=directional_v2', 'status=missed')
    get latest_signals_path
    expect(response.parsed_body['latest_id']).to eq(0)
  end

end
