require "rails_helper"

RSpec.describe "Sound notifications", type: :request do
  it "renders legacy volume events with a neutral price icon" do
    instrument = create_instrument
    instrument.signals.create!(kind: "volume", title: "Old volume", event_key: "legacy-icon", occurred_at: Time.current)
    get root_path(tab: "events")
    icon = Nokogiri::HTML(response.body).at_css(".signal-symbol.price-flat")
    expect(icon.text).to eq("→")
    expect(icon["aria-label"]).to include("не определено")
  end

  it "rounds level ranges and the crossing price to tenths" do
    instrument = create_instrument
    instrument.signals.create!(kind: "crossing", title: "Level crossing", event_key: "rounded-crossing", occurred_at: Time.current,
      details: { side: "resistance", lower: "249.679154367", upper: "256.376169127", price: "257.04123" })
    get root_path(tab: "events")
    text = Nokogiri::HTML(response.body).at_css(".signal p").text
    expect(text).to include("Сопротивление 249,7–256,4 · цена 257")
    expect(text).not_to include("249.679154367")
  end

  it "returns an uncached empty cursor before any events exist" do
    get latest_signals_path
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq("latest_id" => 0)
    expect(response.headers["Cache-Control"]).to include("no-store")
  end

  it "detects new inserts even when their market timestamp is older" do
    instrument = create_instrument
    MarketSignal.create!(instrument: instrument, kind: "volume", title: "Volume", event_key: "sound-volume", occurred_at: Time.current)
    latest = MarketSignal.create!(instrument: instrument, kind: "breakout", title: "Level", event_key: "sound-level", occurred_at: 1.hour.ago)
    get latest_signals_path
    expect(response.parsed_body).to eq("latest_id" => latest.id)
  end

  it "provides a persistent sound control on the dashboard and instrument screen" do
    instrument = create_instrument
    [root_path, instrument_path(instrument)].each do |path|
      get path
      page = Nokogiri::HTML(response.body)
      control = page.at_css("#signal-sound[data-turbo-permanent]")
      expect(control["data-signal-sound-url-value"]).to eq(latest_signals_path)
      expect(control.at_css("button")["aria-pressed"]).to eq("false")
      expect(control.at_css("button")["aria-label"]).to eq("Включить звук")
      expect(control.at_css("button svg .sound-waves")).to be_present
      expect(control.at_css("button svg .sound-muted")).to be_present
    end
  end

  it "offers deletion in both feeds and removes only the requested event without reloading" do
    instrument = create_instrument
    signal = instrument.signals.create!(kind: "volume", title: "Test volume", event_key: "delete-this", occurred_at: Time.current)
    other = instrument.signals.create!(kind: "volume", title: "Keep volume", event_key: "keep-this", occurred_at: Time.current)
    [root_path(tab: "events"), instrument_path(instrument)].each do |path|
      get path
      page = Nokogiri::HTML(response.body)
      form = page.at_css("#market_signal_#{signal.id} form")
      expect(form["action"]).to eq(signal_path(signal))
      expect(form.at_css("input[name='_method']")["value"]).to eq("delete")
      expect(form.at_css("button[aria-label] svg")).to be_present
    end

    delete signal_path(signal), headers: { "ACCEPT" => "text/vnd.turbo-stream.html", "Turbo-Frame" => "dashboard" }
    expect(response).to have_http_status(:ok)
    stream = Nokogiri::HTML.fragment(response.body).at_css("turbo-stream")
    expect(stream["action"]).to eq("remove")
    expect(stream["target"]).to eq("market_signal_#{signal.id}")
    expect(MarketSignal.exists?(signal.id)).to be false
    expect(MarketSignal.exists?(other.id)).to be true
    expect(Instrument.exists?(instrument.id)).to be true
  end

  it "returns to the event feed without Turbo and renders the empty state" do
    instrument = create_instrument
    signal = instrument.signals.create!(kind: "volume", title: "Last event", event_key: "last-event", occurred_at: Time.current)
    delete signal_path(signal)
    expect(response).to have_http_status(:see_other)
    expect(response).to redirect_to(root_path(tab: "events"))
    follow_redirect!
    page = Nokogiri::HTML(response.body)
    expect(page.css(".signal-list .signal")).to be_empty
    expect(page.at_css(".signal-list .empty").text).to include("Пока без событий")
  end
end
