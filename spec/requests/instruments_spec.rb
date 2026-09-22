require "rails_helper"

RSpec.describe "Instrument screens", type: :request do
  let!(:instrument) { create_instrument }

  it "updates the volume checkbox independently" do
    patch instrument_path(instrument), params: { instrument: { volume_enabled: "0" } }
    expect(response).to have_http_status(:redirect)
    expect(instrument.reload).to have_attributes(volume_enabled: false, breakout_enabled: true, enabled: true)
  end

  it "keeps the settings form redirect when Turbo submits from the instrument page" do
    patch instrument_path(instrument), params: { instrument: { volume_multiplier: 4 } },
      headers: { "ACCEPT" => "text/vnd.turbo-stream.html", "HTTP_REFERER" => instrument_url(instrument) }

    expect(response).to redirect_to(instrument_url(instrument))
    expect(instrument.reload.volume_multiplier).to eq(4)
  end

  describe "checkbox autosave" do
    let(:stream_headers) { { "ACCEPT" => "text/vnd.turbo-stream.html", "Turbo-Frame" => "dashboard" } }

    %w[enabled volume_enabled breakout_enabled].each do |field|
      it "saves #{field} without redirecting or replacing the page" do
        patch instrument_path(instrument), params: { instrument: { field => "0" } }, headers: stream_headers

        expect(response).to have_http_status(:ok)
        expect(response.media_type).to eq("text/vnd.turbo-stream.html")
        expect(response.headers["Location"]).to be_nil
        expect(instrument.reload.public_send(field)).to be false

        streams = Nokogiri::HTML.fragment(response.body)
        expect(streams.css("turbo-stream").map { |node| [node["action"], node["target"]] }).to eq([
          ["replace", "instrument_#{instrument.id}"], ["update", "watched-instruments-count"]
        ])
        checkbox = streams.at_css("input[type='checkbox'][name='instrument[#{field}]']")
        expect(checkbox["checked"]).to be_nil
        expected_count = field == "enabled" ? "0" : "1"
        expect(streams.at_css("turbo-stream[target='watched-instruments-count'] template").text).to eq(expected_count)
      end
    end

    it "returns saved values and an inline error when validation fails" do
      patch instrument_path(instrument), params: { instrument: { enabled: "0", volume_multiplier: 0 } }, headers: stream_headers

      expect(response.status).to eq(422)
      expect(response.headers["Location"]).to be_nil
      expect(instrument.reload.enabled).to be true
      streams = Nokogiri::HTML.fragment(response.body)
      expect(streams.at_css("input[type='checkbox'][name='instrument[enabled]']")["checked"]).not_to be_nil
      expect(streams.at_css("[data-autosave-feedback]").text).to be_present
    end
  end

  it "renders the dashboard" do
    get root_path
    expect(response).to have_http_status(:ok)
    page = Nokogiri::HTML(response.body)
    expect(page.at_css("h1").text).to eq("Рынок под наблюдением")
    forms = page.css("#instrument_#{instrument.id} form[data-controller='autosave']")
    expect(forms.size).to eq(4)
    expect(forms.map { |form| form["data-turbo-frame"] }).to all(be_nil)
  end

  it "renders the instrument chart with candles and a level" do
    2.times do |index|
      instrument.candles.create!(timeframe: "day", time: (index + 1).days.ago, open: 100, high: 103, low: 99, close: 101, volume: 1000)
    end
    instrument.price_levels.create!(source: "manual", timeframe: "day", side: "resistance", price: 102)

    get instrument_path(instrument)
    expect(response).to have_http_status(:ok)
    expect(Nokogiri::HTML(response.body).css("svg.chart .chart-candle rect").size).to eq(2)
  end
  it "provides a confirmed delete action in the watchlist and returns the updated dashboard" do
    other = create_instrument(ticker: "KEEP")
    instrument.candles.create!(timeframe: "day", time: 1.day.ago, open: 100, high: 101, low: 99, close: 100, volume: 10)
    get root_path
    row = Nokogiri::HTML(response.body).at_css("#instrument_#{instrument.id}")
    button = row.at_css("button.instrument-delete-button")
    expect(button["aria-label"]).to eq("Удалить TEST из наблюдения")
    form = button.ancestors("form").first
    expect(form["action"]).to eq(instrument_path(instrument))
    expect(form["data-turbo-confirm"]).to include("TEST", "свечи", "уровни", "сигналов")
    expect(form["data-turbo-frame"]).to eq("dashboard")
    expect(form.at_css("input[name='_method']")["value"]).to eq("delete")

    delete instrument_path(instrument), headers: { "Turbo-Frame" => "dashboard" }
    expect(response).to have_http_status(:see_other)
    expect(Instrument.exists?(instrument.id)).to be false
    expect(Candle.where(instrument_id: instrument.id)).to be_empty
    expect(Instrument.exists?(other.id)).to be true
    follow_redirect!
    page = Nokogiri::HTML(response.body)
    expect(page.at_css("turbo-frame#dashboard")).to be_present
    expect(page.at_css("#instrument_#{instrument.id}")).to be_nil
    expect(page.at_css("#instrument_#{other.id}")).to be_present
  end

end
