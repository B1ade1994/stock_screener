require 'rails_helper'

RSpec.describe 'Current daily candle chart', type: :request do
  around { |example| travel_to(Time.zone.local(2026, 10, 19, 16)) { example.run } }

  it 'reserves a chart-only daily slot and leaves weekly charts and EMA calculations on completed history' do
    instrument = create_instrument
    21.times do |index|
      instrument.candles.create!(timeframe: 'day', time: (index + 1).days.ago.utc.beginning_of_day,
        open: 100, high: 102, low: 98, close: 101, volume: 500)
    end
    get instrument_path(instrument)
    page = Nokogiri::HTML(response.body)
    expect(page.css('.chart-candle').size).to eq(21)
    expect(page.at_css('.chart-live-candle')['display']).to eq('none')
    expect(page.at_css('[data-chart-cursor-quote-url-value]')['data-chart-cursor-quote-url-value']).to include('live_candle=day')
    expect(page.at_css('.chart-ema[data-period="20"]')['points'].split.size).to eq(2)
    expect(page.text).to include('Последняя свеча формируется', 'Загружено завершённых свечей: 21')

    instrument.candles.create!(timeframe: 'week', time: 7.days.ago, open: 100, high: 102, low: 98, close: 101, volume: 500)
    get instrument_path(instrument, timeframe: 'week')
    expect(Nokogiri::HTML(response.body).at_css('.chart-live-candle')).to be_nil
  end

  it 'serves the current OHLC only when requested and keeps the quote usable on missing candle data' do
    instrument = create_instrument(last_price: 104, last_trade_at: Time.current)
    expect(CurrentDayCandle).not_to receive(:call)
    get quote_instrument_path(instrument)
    expect(response.parsed_body).not_to have_key('candle')
  end

  it 'serves uncached quote responses with a separate live snapshot without adding historical candles' do
    instrument = create_instrument(last_price: 104, last_trade_at: Time.current)
    bar = { 'time' => Time.current.utc.beginning_of_day.iso8601, 'open' => 100, 'high' => 105, 'low' => 99, 'close' => 104, 'volume' => 150 }
    expect(CurrentDayCandle).to receive(:call).with(instrument).and_return(bar)
    expect { get quote_instrument_path(instrument, live_candle: 'day') }.not_to change(Candle, :count)
    expect(response.parsed_body).to include('candle' => bar, 'period_start' => Time.current.utc.beginning_of_day.iso8601)
    expect(response.headers['Cache-Control']).to include('no-store')
  end
end
