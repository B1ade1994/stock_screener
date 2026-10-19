require 'rails_helper'

RSpec.describe 'Daily statistics', type: :request do
  around { |example| travel_to(Time.zone.local(2026, 9, 23, 12, 0, 36)) { example.run } }

  it 'renders date and horizon selection, quality and paired comparison, including an empty day' do
    get statistics_path(date: '2026-09-23', horizon: '60')
    expect(response).to have_http_status(:ok)
    page = Nokogiri::HTML(response.body)
    expect(page.at_css('input[name=date]')['value']).to eq('2026-09-23')
    expect(page.at_css('select[name=horizon] option[selected]')['value']).to eq('60')
    expect(page.at_css('input[name=full][type=checkbox]')['checked']).to be_present
    expect(page.at_css('#daily-statistics')['data-refresh-interval-value']).to eq('60000')
    expect(page.text).to include('Полнота данных', 'Парных наблюдений', 'Нет отсчёта')
    expect(page.at_css("a[href='#{statistics_path}'][aria-current=page]")).to be_present
    get statistics_path(date: 'not-a-date')
    expect(response).to have_http_status(:bad_request)
  end

  it 'renders both measurements in the event feed and preserves the sound event id' do
    instrument = create_instrument
    signal = instrument.signals.create!(kind: 'reversal', reversal_status: 'possible', event_key: 'both', title: 'Откуп', occurred_at: Time.current, details: { direction: 'up' })
    travel 2.minutes
    signal.update!(reversal_status: 'confirmed')
    get root_path(tab: 'events')
    page = Nokogiri::HTML(response.body)
    expect(page.css('.signal-reaction').size).to eq(2)
    expect(page.text).to include('После уведомления', 'После подтверждения')
    get latest_signals_path
    expect(response.parsed_body['latest_id']).to eq(signal.id)
    get statistics_path(date: '2026-09-23', full: '0'), headers: { 'Turbo-Frame' => 'daily-statistics' }
    expect(Nokogiri::HTML(response.body).at_css('turbo-frame#daily-statistics')).to be_present
  end

  it 'preserves cost assumptions during refresh and rejects malformed inputs' do
    get statistics_path(date: '2026-09-23', commission_per_side: '0.01', spread: '0.02', slippage_per_side: '0.005')
    expect(response).to have_http_status(:ok)
    page = Nokogiri::HTML(response.body)
    expect(page.text).to include('0.050%', 'Сценарии без повторного подсчёта этапов')
    refresh = page.at_css('#daily-statistics')['data-refresh-url-value']
    expect(refresh).to include('commission_per_side=0.01', 'spread=0.02', 'slippage_per_side=0.005')
    %w[-1 NaN invalid].each do |value|
      get statistics_path(spread: value)
      expect(response).to have_http_status(:bad_request)
    end
  end

  it 'shows linked research stages without including unrelated events in a scenario timeline' do
    instrument = create_instrument
    root = instrument.signals.create!(kind: 'volume', title: 'Source volume', event_key: 'source', occurred_at: Time.current)
    child = instrument.signals.create!(kind: 'volume_followthrough', title: 'Held volume', event_key: 'child',
      occurred_at: Time.current, research_only: true, details: { source_id: root.id })
    instrument.signals.create!(kind: 'volume', title: 'Unrelated volume', event_key: 'other', occurred_at: Time.current)
    get signal_path(child)
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('Source volume', 'Held volume', 'исследовательское')
    expect(response.body).not_to include('Unrelated volume')
  end

  it 'shows prospective TA context on a scenario and defaults the comparison horizon to 30 minutes' do
    instrument = create_instrument
    source = instrument.signals.create!(kind: 'reversal', title: 'Source', event_key: 'ta-source', occurred_at: Time.current,
      details: { direction: 'up', entry_price: '100', extreme: '98', volatility: '1', rebound_boundary: '100.5', last_checked_at: 1.minute.ago.iso8601 })
    get signal_path(source)
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('ТА-контекст', 'Недостаточно истории', 'отдельный откат')
    get statistics_path
    page = Nokogiri::HTML(response.body)
    expect(page.at_css('select[name=horizon] option[selected]')['value']).to eq('30')
    expect(page.text).to include('ТА: расположение у зоны и структура', 'Старые сигналы не размечаются сегодняшними зонами')
  end
end
