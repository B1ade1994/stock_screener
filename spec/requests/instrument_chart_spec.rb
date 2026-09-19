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
    expect(frame.at_css("[data-controller='chart-cursor']")["data-chart-cursor-start-index-value"]).to eq("0")
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
  it "plots volume bars on both timeframes, including zero volume" do
    %w[day week].each do |timeframe|
      candle(timeframe, 2.days.ago).update!(volume: 0)
      candle(timeframe, 1.day.ago).update!(volume: 200)
      get instrument_path(instrument, timeframe: timeframe)
      page = Nokogiri::HTML(response.body)
      bars = page.css(".chart-volume")
      expect(bars.map { |bar| bar["data-volume"].to_i }).to eq([0, 200])
      expect(bars.map { |bar| bar["height"].to_f }).to eq([0, 80])
      expect(page.at_css("[data-chart-cursor-target='volume']")).to be_present
    end
  end

  it "shows level evidence and distance independently from its score" do
    instrument.update!(last_price: 100)
    level = instrument.price_levels.create!(price: 130, timeframe: "day", side: "resistance", source: "automatic", touches: 2,
      assessment: { score: 5.4, relative_volume: 2.5, volume_samples: 2, reaction_percent: 1.2, last_touch_at: "2026-09-01T00:00:00Z", as_of: "2026-09-10T00:00:00Z" })
    get instrument_path(instrument)
    row = Nokogiri::HTML(response.body).at_css("[data-price-level-id='#{level.id}']")
    expect(row.text).to include("×2.50", "01.09.2026", "+30.00%", "5.40", "1.20%")
  end

  it "draws full zone bounds and available EMA series on both periods" do
    level = instrument.price_levels.create!(price: 130, lower_price: 125, upper_price: 135, atr: 4, timeframe: "day", side: "resistance", source: "automatic")
    %w[day week].each do |tf|
      55.times { |i| candle(tf, (56 - i).days.ago, 100 + i) }
      get instrument_path(instrument, timeframe: tf)
      page = Nokogiri::HTML(response.body)
      zone = page.at_css(".chart-zone[data-level-id='#{level.id}']")
      expect(zone["height"].to_f).to be > 0
      expect(page.css(".chart-ema").map { |el| el["data-period"] }).to eq(tf == "day" ? %w[20 50] : %w[20 40])
      expect(page.text).to include("EMA", "Подтверждённая", "125.00–135.00")
    end
  end

  it "keeps plot clipping separate from the stationary scales and cursor" do
    candle("day", 1.day.ago)
    get instrument_path(instrument)
    page = Nokogiri::HTML(response.body)
    svg = page.at_css("svg.chart")
    expect(svg.css("defs > clippath").size).to eq(2)
    expect(svg.at_css("[data-chart-cursor-target='pricePlot']").parent["clip-path"]).to include("chart-price-clip")
    expect(svg.at_css("[data-chart-cursor-target='volumePlot']").parent["clip-path"]).to include("chart-volume-clip")
    expect(svg.css("[data-chart-cursor-target='priceTick']").size).to eq(5)
    expect(svg.at_css("[data-chart-cursor-target='cursor']").parent).to eq(svg)
    expect(page.css(".chart-controls, #chart-navigation-help")).to be_empty
  end

  it "shows relative strength, its score and matching chart tooltip" do
    candle("day", 1.day.ago)
    levels = [1, 2, 5].map do |score|
      instrument.price_levels.create!(price: 100 + score, timeframe: "day", side: "resistance", source: "automatic", touches: 2,
        assessment: { version: Detectors::Levels::VERSION, score: score, as_of: Time.current.iso8601 })
    end
    get instrument_path(instrument)
    page = Nokogiri::HTML(response.body)
    expect(page.css(".level-strength").map { |node| node["data-strength"] }).to eq(%w[1 2 3])
    expect(page.css("svg [data-chart-level-id]").map { |node| node["data-level-strength"] }).to eq(%w[1 2 3])
    expect(page.css("[data-chart-strength-filter-target='choice']").map { |node| node["value"] }).to eq(%w[3 2 1 unrated])
    row = page.at_css("tr[data-price-level-id='#{levels.last.id}']")
    expect(row.text).to include("Высокая", "5.00", "среди 1D")
    expect(page.at_css(".chart-level[data-level-id='#{levels.last.id}'] title").text).to include("Сила: Высокая")
  end

  it "keeps unrated and eye-hidden metadata separate from the strength filter" do
    candle("day", 1.day.ago)
    manual = instrument.price_levels.create!(price: 100, timeframe: "day", side: "support", source: "manual", chart_visible: false)
    get instrument_path(instrument)
    page = Nokogiri::HTML(response.body)
    group = page.at_css("svg [data-chart-level-id='#{manual.id}']")
    expect(group["data-level-strength"]).to eq("unrated")
    expect(group["data-chart-visible"]).to eq("false")
    expect(group["display"]).to eq("none")
    expect(page.at_css("[data-controller='chart-strength-filter']")["data-chart-strength-filter-instrument-value"]).to eq(instrument.id.to_s)
    expect(page.at_css("tr[data-price-level-id='#{manual.id}']")).to be_present
  end

  it "opens daily history at two calendar months before the latest candle without dropping older bars" do
    %w[2025-12-01 2026-02-27 2026-02-28 2026-03-02 2026-03-10 2026-04-01 2026-04-10 2026-04-30].each do |date|
      candle("day", Time.iso8601("#{date}T00:00:00Z"))
    end
    get instrument_path(instrument)
    page = Nokogiri::HTML(response.body)
    expect(page.at_css("svg.chart")["data-timeframe"]).to eq("day")
    expect(page.at_css("[data-controller='chart-cursor']")["data-chart-cursor-start-index-value"]).to eq("2")
    expect(page.css(".chart-candle").size).to eq(8)
  end

  it "opens all available daily history when it is shorter than two months" do
    candle("day", 2.days.ago)
    candle("day", 1.day.ago)
    get instrument_path(instrument)
    page = Nokogiri::HTML(response.body)
    expect(page.at_css("[data-controller='chart-cursor']")["data-chart-cursor-start-index-value"]).to eq("0")
  end

  it "supplies the last trade to the stationary price marker on both chart periods" do
    time = Time.iso8601("2026-09-19T12:00:00Z")
    instrument.update!(last_price: 123.45, last_trade_at: time)
    %w[day week].each do |timeframe|
      candle(timeframe, 1.week.ago)
      get instrument_path(instrument, timeframe: timeframe)
      page = Nokogiri::HTML(response.body)
      controller = page.at_css("[data-controller='chart-cursor']")
      expect(controller["data-chart-cursor-last-price-value"].to_d).to eq(123.45.to_d)
      expect(Time.iso8601(controller["data-chart-cursor-last-trade-at-value"])).to eq(time)
      expect(controller["data-chart-cursor-quote-url-value"]).to eq(quote_instrument_path(instrument))
      marker = page.at_css("[data-chart-cursor-target='currentPrice']")
      expect(marker.parent).to eq(page.at_css("svg.chart"))
      expect(marker.css("[data-chart-cursor-target='currentPriceLine']").size).to eq(1)
      expect(marker.css("[data-chart-cursor-target='currentPriceText']").size).to eq(1)
    end
  end

  it "returns the latest stored trade without caching or substituting a candle close" do
    candle("day", 1.day.ago, 100)
    get quote_instrument_path(instrument), as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq("price" => nil, "traded_at" => nil)
    expect(response.headers["Cache-Control"]).to include("no-store")

    time = Time.iso8601("2026-09-19T12:01:00Z")
    instrument.update!(last_price: 125.75, last_trade_at: time)
    get quote_instrument_path(instrument), as: :json
    expect(response.parsed_body.fetch("price").to_d).to eq(125.75.to_d)
    expect(Time.iso8601(response.parsed_body.fetch("traded_at"))).to eq(time)
  end

  it "renders imported price history without presenting missing futures volume as zero" do
    candle("day", 2.days.ago).update!(data_source: "yahoo_spy", volume: nil, reference_volume: 50_000_000)
    candle("day", 1.day.ago)
    get instrument_path(instrument)
    expect(response).to have_http_status(:ok)
    page = Nokogiri::HTML(response.body)
    expect(page.text).to include("Ранняя история дополнена SPY")
    imported = page.at_css(".chart-candle[data-source='yahoo_spy']")
    expect(imported["data-volume"]).to eq("")
    expect(imported.at_css("title").text).to include("SPY · Yahoo Finance")
    expect(page.at_css(".chart-volume[data-source='yahoo_spy'] title").text).to include("объём SP500F недоступен")
  end

end
