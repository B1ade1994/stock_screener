require "rails_helper"

RSpec.describe "Instrument chart", type: :request do
  let!(:instrument) { create_instrument }

  def candle(timeframe, time, price = 100)
    instrument.candles.create!(timeframe: timeframe, time: time, open: price, high: price + 3, low: price - 1, close: price + 1, volume: 1000)
  end

  it "shows all daily candles in chronological order, including candles older than the last 60" do
    65.times { |index| candle("day", (index + 1).days.ago.beginning_of_day) }
    candle("week", 2.weeks.ago.beginning_of_week)

    get instrument_path(instrument)
    expect(response).to have_http_status(:ok)
    page = Nokogiri::HTML(response.body)
    expect(page.css(".chart-candle").size).to eq(65)
    expect(page.css(".chart-candle").map { |node| Time.iso8601(node["data-time"]) }).to eq(instrument.candles.where(timeframe: "day").order(:time).pluck(:time))
    expect(page.at_css(".chart-periods [aria-current='page']").text).to eq("День · 1D")
  end

  it "switches to all weekly candles in a Turbo frame" do
    candle("day", 1.day.ago)
    70.times { |index| candle("week", (index + 1).weeks.ago.beginning_of_week) }

    get instrument_path(instrument, timeframe: "week"), headers: { "Turbo-Frame" => "instrument-chart" }
    expect(response).to have_http_status(:ok)
    frame = Nokogiri::HTML(response.body).at_css("turbo-frame#instrument-chart")
    expect(frame.css(".chart-candle").size).to eq(70)
    expect(frame.at_css("svg")["data-timeframe"]).to eq("week")
    expect(frame.at_css(".chart-periods [aria-current='page']").text).to eq("Неделя · 1W")
  end

  it "keeps daily and weekly levels above and below the candles inside either chart" do
    candle("day", 1.day.ago)
    candle("week", 1.week.ago)
    levels = [
      instrument.price_levels.create!(price: 10, timeframe: "day", side: "support", source: "manual"),
      instrument.price_levels.create!(price: 250, timeframe: "week", side: "resistance", source: "manual")
    ]
    instrument.price_levels.create!(price: 900, timeframe: "day", side: "resistance", source: "manual", active: false)

    %w[day week].each do |timeframe|
      get instrument_path(instrument, timeframe: timeframe)
      page = Nokogiri::HTML(response.body)
      lines = page.css("svg .chart-level")
      expect(lines.map { |node| node["data-level-id"].to_i }).to match_array(levels.map(&:id))
      expect(lines.map { |node| node["y1"].to_f }).to all(be_between(40, 280).exclusive)
      expect(lines.map { |node| node.at_css("title").text }).to include(a_string_including("1D"), a_string_including("1W"))
    end
  end

  it "shows an empty weekly state without substituting daily candles" do
    candle("day", 1.day.ago)
    get instrument_path(instrument, timeframe: "week")
    page = Nokogiri::HTML(response.body)
    expect(page.css("svg.chart")).to be_empty
    expect(page.text).to include("Недельные свечи ещё не загружены")
    expect(page.css(".chart-periods a").size).to eq(2)
  end

  it "falls back to daily candles for an unknown timeframe" do
    candle("day", 1.day.ago)
    get instrument_path(instrument, timeframe: "invalid")
    expect(Nokogiri::HTML(response.body).at_css("svg.chart")["data-timeframe"]).to eq("day")
  end
end
