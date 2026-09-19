require "rails_helper"

RSpec.describe "Price level chart visibility", type: :request do
  let(:instrument) { create_instrument }
  let!(:level) { instrument.price_levels.create!(price: 100, lower_price: 99, upper_price: 101, timeframe: "day", side: "resistance", source: "automatic") }

  def set_visibility(value, extra = {})
    patch instrument_price_level_path(instrument, level), params: { price_level: { chart_visible: value }.merge(extra) }, as: :json
  end

  it "persists hiding and showing without deleting or disabling the level" do
    expect { set_visibility(false) }.not_to change(PriceLevel, :count)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("id" => level.id, "chart_visible" => false)
    expect(response.headers["Location"]).to be_nil
    expect(level.reload).to have_attributes(chart_visible: false, active: true, status: "confirmed")
    expect(instrument.price_levels.alertable).to include(level)
    set_visibility(true)
    expect(response).to have_http_status(:ok)
    expect(level.reload.chart_visible?).to be true
  end

  it "hides both the zone and its center line on D/W while preserving the table row" do
    %w[day week].each do |timeframe|
      instrument.candles.create!(timeframe: timeframe, time: 2.days.ago, open: 100, high: 105, low: 95, close: 102, volume: 100)
    end
    set_visibility(false)
    %w[day week].each do |timeframe|
      get instrument_path(instrument, timeframe: timeframe)
      page = Nokogiri::HTML(response.body)
      group = page.at_css("svg [data-chart-level-id='#{level.id}']")
      expect(group["display"]).to eq("none")
      expect(group.css(".chart-zone, .chart-level").size).to eq(2)
      row = page.at_css("tr[data-price-level-id='#{level.id}']")
      expect(row).to be_present
      expect(row.at_css(".level-visibility-button")["aria-pressed"]).to eq("false")
    end
    set_visibility(true)
    get instrument_path(instrument)
    expect(Nokogiri::HTML(response.body).at_css("svg [data-chart-level-id='#{level.id}']")["display"]).to eq("inline")
  end

  it "works for manual levels as well" do
    level.update!(source: "manual")
    set_visibility(false)
    expect(level.reload).to have_attributes(chart_visible: false, active: true, source: "manual", price: 100)
  end

  it "permits only the chart visibility setting" do
    set_visibility(false, active: false, price: 999, status: "archived")
    expect(level.reload).to have_attributes(chart_visible: false, active: true, price: 100, status: "confirmed")
  end

  it "rejects invalid or missing visibility" do
    set_visibility("invalid")
    expect(response).to have_http_status(:unprocessable_content)
    expect(level.reload.chart_visible?).to be true
    patch instrument_price_level_path(instrument, level), params: { price_level: { active: false } }, as: :json
    expect(response).to have_http_status(:unprocessable_content)
    expect(level.reload.active?).to be true
  end

  it "does not change a level belonging to a different instrument" do
    other = create_instrument
    patch instrument_price_level_path(other, level), params: { price_level: { chart_visible: false } }, as: :json
    expect(response).to have_http_status(:not_found)
    expect(level.reload.chart_visible?).to be true
  end
end
