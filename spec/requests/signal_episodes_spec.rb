require "rails_helper"

RSpec.describe "Signal episodes", type: :request do
  around { |example| travel_to(Time.zone.local(2026, 9, 21, 12, 0, 36)) { example.run } }

  it "keeps the sound cursor stable on updates and renders accumulated bursts and price outcomes in both feeds" do
    instrument = create_instrument(ticker: "SBER")
    details = { buy: 900, sell: 100, unknown: 0, volume: 1000, baseline: 100, ratio: 10.0, buy_percent: 90.0, open_price: "100", close_price: "101" }
    bar = MarketMinute.new(time: Time.current.beginning_of_minute - 60, session: SecureRandom.uuid)
    signal = VolumeEpisode.record(instrument: instrument, bar: bar, details: details)
    get latest_signals_path
    cursor = response.parsed_body
    travel 2.minutes
    bar.time += 2.minutes
    VolumeEpisode.record(instrument: instrument, bar: bar, details: details.merge(open_price: "101", close_price: "99"))
    signal.reaction.update!(reference_price: 100, results: { "5" => { "status" => "measured", "price" => "99.5", "change_percent" => -0.5, "high_percent" => 0.1, "low_percent" => -0.8, "candles" => 5 } })
    get latest_signals_path
    expect(response.parsed_body).to eq(cursor)

    [root_path(tab: "events"), instrument_path(instrument), events_instrument_path(instrument)].each do |path|
      get path
      expect(response).to have_http_status(:ok)
      page = Nokogiri::HTML(response.body)
      expect(page.css(".signal").size).to eq(1)
      expect(page.css(".episode-bursts tbody tr").size).to eq(2)
      expect(page.css(".reaction-outcome.price-down").text).to include("-0.50%")
      expect(page.at_css(".signal-symbol.price-down").text).to eq("↘")
      expect(page.at_css(".signal-symbol")['aria-label']).to include("Цена снизилась")
      expect(page.css(".reaction-outcomes").text).to include("15 мин: ожидаем")
    end
    frame = Nokogiri::HTML(response.body).at_css("turbo-frame#instrument-signals[data-controller='refresh']")
    expect(frame['data-refresh-url-value']).to eq(events_instrument_path(instrument))
    delete signal_path(signal), headers: { "ACCEPT" => "text/vnd.turbo-stream.html" }
    expect(response).to have_http_status(:ok)
    expect(SignalReaction.exists?(signal_id: signal.id)).to be false
  end
end
