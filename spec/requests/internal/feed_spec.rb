require "rails_helper"

RSpec.describe "Internal market feed", type: :request do
  let!(:instrument) { create_instrument }
  let(:headers) { { "Authorization" => "Bearer test-internal-secret" } }

  around do |example|
    old_token = ENV["INTERNAL_API_TOKEN"]
    ENV["INTERNAL_API_TOKEN"] = "test-internal-secret"
    travel_to(Time.zone.local(2026, 9, 19, 12)) { example.run }
  ensure
    ENV["INTERNAL_API_TOKEN"] = old_token
  end

  it "requires a secret" do
    get "/internal/watchlist"
    expect(response).to have_http_status(:unauthorized)
  end

  it "returns watched instruments with the correct secret" do
    get "/internal/watchlist", headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("instruments")).to eq([instrument.uid])
  end

  it "excludes disabled instruments" do
    instrument.update!(enabled: false)
    get "/internal/watchlist", headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("instruments")).to eq([])
  end

  it "handles snapshot retries idempotently and does not overwrite a newer price" do
    payload = {
      status: "connected",
      instruments: [{
        uid: instrument.uid,
        price: "120.5",
        trade_time: 1.second.ago.iso8601,
        bars: [{ time: 2.minutes.ago.iso8601, session: SecureRandom.uuid, buy: 30, sell: 10, unknown: 0, trades: 4, open_price: "119.5", close_price: "120.5", complete: true }]
      }]
    }

    expect do
      2.times do
        post "/internal/ingest", params: payload, headers: headers, as: :json
        expect(response).to have_http_status(:no_content)
      end
    end.to change(MarketMinute, :count).by(1)
    expect(MarketMinute.last).to have_attributes(buy: 30, open_price: BigDecimal("119.5"), close_price: BigDecimal("120.5"))
    expect(instrument.reload.last_price).to eq(BigDecimal("120.5"))

    payload[:instruments][0].merge!(price: "1", trade_time: 5.minutes.ago.iso8601)
    post "/internal/ingest", params: payload, headers: headers, as: :json
    expect(response).to have_http_status(:no_content)
    expect(instrument.reload.last_price).to eq(BigDecimal("120.5"))
  end

  it "rejects invalid minute prices without rejecting valid volume" do
    post "/internal/ingest", headers: headers, as: :json, params: {
      status: "connected", instruments: [{ uid: instrument.uid,
        bars: [{ time: 2.minutes.ago.iso8601, session: SecureRandom.uuid, buy: 30, sell: 10, unknown: 0, trades: 4,
          open_price: "not-a-price", close_price: "NaN", complete: true }] }]
    }
    expect(response).to have_http_status(:no_content)
    expect(instrument.market_minutes.last).to have_attributes(open_price: nil, close_price: nil)
  end
  it "subscribes to gold by UID and ingests its minute volumes and price" do
    instrument.update!(ticker: "GLDRUB_TOM", kind: "currency", class_code: "CETS")
    get "/internal/watchlist", headers: headers
    expect(response.parsed_body.fetch("instruments")).to include(instrument.uid)
    post "/internal/ingest", headers: headers, as: :json, params: {
      status: "connected", instruments: [{ uid: instrument.uid, price: "11829.5", trade_time: 1.second.ago.iso8601,
        bars: [{ time: 2.minutes.ago.iso8601, session: SecureRandom.uuid, buy: 30, sell: 10, unknown: 0, trades: 4, complete: true }] }]
    }
    expect(response).to have_http_status(:no_content)
    expect(instrument.reload.last_price).to eq(BigDecimal("11829.5"))
    expect(instrument.market_minutes.last).to have_attributes(buy: 30, sell: 10, complete: true)
  end

end
