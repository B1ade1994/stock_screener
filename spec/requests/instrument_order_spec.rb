require "rails_helper"

RSpec.describe "Instrument order", type: :request do
  let!(:first) { create_instrument(ticker: "ZZZ") }
  let!(:middle) { create_instrument(ticker: "AAA", enabled: false) }
  let!(:last) { create_instrument(ticker: "MMM") }

  it "moves a row directly to the beginning without redirecting and keeps that order on reload" do
    patch move_instrument_path(last), params: { target_id: first.id, placement: "before" }, as: :json

    expect(response).to have_http_status(:no_content)
    expect(response.headers["Location"]).to be_nil
    expect(Instrument.in_display_order.ids).to eq([last.id, first.id, middle.id])
    expect(middle.reload).to have_attributes(enabled: false, volume_enabled: true, breakout_enabled: true)

    get root_path
    page = Nokogiri::HTML(response.body)
    expect(page.css("#instruments-list > tr").map { |row| row["id"] }).to eq([last, first, middle].map { |item| "instrument_#{item.id}" })
    expect(page.css("#instruments-list .drag-handle").size).to eq(3)
    expect(page.css("#instruments-list button[name='direction']")).to be_empty
  end

  it "moves a row directly to the end" do
    patch move_instrument_path(first), params: { target_id: last.id, placement: "after" }, as: :json
    expect(response).to have_http_status(:no_content)
    expect(Instrument.in_display_order.ids).to eq([middle.id, last.id, first.id])
  end

  it "inserts a row between two instruments" do
    patch move_instrument_path(last), params: { target_id: first.id, placement: "after" }, as: :json
    expect(response).to have_http_status(:no_content)
    expect(Instrument.in_display_order.ids).to eq([first.id, last.id, middle.id])
  end

  it "leaves the order unchanged when the target is the same instrument" do
    patch move_instrument_path(middle), params: { target_id: middle.id, placement: "before" }, as: :json
    expect(response).to have_http_status(:no_content)
    expect(Instrument.in_display_order.ids).to eq([first.id, middle.id, last.id])
  end

  it "rejects invalid placements without changing the order" do
    patch move_instrument_path(middle), params: { target_id: last.id, placement: "sideways" }, as: :json
    expect(response).to have_http_status(:bad_request)
    expect(Instrument.in_display_order.ids).to eq([first.id, middle.id, last.id])
  end

  it "requires a target" do
    patch move_instrument_path(middle), params: { placement: "before" }, as: :json
    expect(response).to have_http_status(:bad_request)
    expect(Instrument.in_display_order.ids).to eq([first.id, middle.id, last.id])
  end

  it "does not partially reorder if the target was deleted" do
    last.destroy!
    patch move_instrument_path(middle), params: { target_id: last.id, placement: "before" }, as: :json
    expect(response).to have_http_status(:not_found)
    expect(Instrument.in_display_order.ids).to eq([first.id, middle.id])
  end
end
