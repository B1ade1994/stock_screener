require 'rails_helper'
require_relative '../support/reversal_helpers'

RSpec.describe 'Reversal events', type: :request do
  include ReversalHelpers
  around { |example| travel_to(Time.zone.local(2026, 9, 22, 14)) { example.run } }

  it 'ingests OHLC and creates exactly one reversal independently from volume' do
    instrument = create_instrument(volume_enabled: false)
    bars = reversal_bars
    bars[0...-1].each { |b| b.instrument = instrument; b.save!; ReversalMinute.record_stream(instrument, b) }
    old_token = ENV['INTERNAL_API_TOKEN']
    ENV['INTERNAL_API_TOKEN'] = 'test-reversal'
    payload = { status: 'connected', instruments: [{ uid: instrument.uid, bars: [bars.last.attributes.except('id', 'instrument_id')] }] }
    2.times do
      post '/internal/ingest', params: payload, as: :json, headers: { 'Authorization' => 'Bearer test-reversal' }
      expect(response).to have_http_status(:no_content)
    end
    expect(instrument.signals.sole.kind).to eq('reversal')
    expect(instrument.market_minutes.order(:time).last.high_price).to eq(bars.last.high_price)
  ensure
    ENV['INTERNAL_API_TOKEN'] = old_token
  end

  it 'has a separate switch and filter, and renders states in both feeds' do
    instrument = create_instrument
    signal = instrument.signals.create!(kind: 'reversal', reversal_status: 'possible', title: 'Откуп после снижения',
      event_key: 'reversal-ui', occurred_at: Time.current, details: Detectors::Reversal.evaluate(bars: reversal_bars))
    instrument.signals.create!(kind: 'volume', title: 'Объём', event_key: 'volume-ui', occurred_at: Time.current)
    instrument.signals.create!(kind: 'crossing', title: 'Уровень', event_key: 'level-ui', occurred_at: Time.current)
    get root_path
    expect(Nokogiri::HTML(response.body).at_css("input[name='instrument[reversal_enabled]'][type='checkbox']")).to be_present
    patch instrument_path(instrument), params: { instrument: { reversal_enabled: false } }
    expect(instrument.reload.reversal_enabled?).to be false
    expect(instrument.volume_enabled?).to be true

    [{}, { 'Turbo-Frame' => 'dashboard' }].each do |headers|
      get root_path(tab: 'events', event_filter: 'reversal'), headers: headers
      page = Nokogiri::HTML(response.body)
      expect(page.css('.signal').size).to eq(1)
      expect(page.at_css('.signal').text).to include('Разворот', 'Возможный', 'После резкого движения')
      expect(page.at_css('.event-filter.active').text).to eq('Развороты')
    end
    %w[volume levels].each do |filter|
      get root_path(tab: 'events', event_filter: filter)
      expect(Nokogiri::HTML(response.body).at_css("#market_signal_#{signal.id}")).to be_nil
    end
    signal.update!(reversal_status: 'confirmed')
    get events_instrument_path(instrument)
    expect(Nokogiri::HTML(response.body).at_css('.reversal-status').text).to eq('Подтверждён')
  end
end
