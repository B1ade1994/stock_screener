require "rails_helper"

RSpec.describe TInvest::Client do
  subject(:client) { described_class.new }

  def item(ticker, type, board)
    { "ticker" => ticker, "instrumentType" => type, "classCode" => board, "uid" => SecureRandom.uuid, "name" => ticker, "currency" => "rub", "lot" => 1 }
  end

  it "includes only supported metals and preserves shares-first ordering and the TQBR filter" do
    gold = item("GLDRUB_TOM", "currency", "CETS")
    silver = item("SLVRUB_TOM", "currency", "CETS")
    future = item("GLDRUBF", "futures", "SPBFUT")
    share = item("SBER", "share", "TQBR")
    excluded = [item("CNYRUB_TOM", "currency", "CETS"), item("GLDRUB_TOM", "currency", "OTHER"), item("SBER", "share", "SPEQ"), item("HEAD", "share", "PTEQ"), item("TGLD", "etf", "TQTF")]
    allow(client).to receive(:call).with("InstrumentsService/FindInstrument", { query: "gold" }).and_return("instruments" => [gold, future, silver, *excluded, share])
    expect(client.search("gold")).to eq([share, gold, future, silver])
  end

  it "loads metals without querying futures details and keeps API currency and lot" do
    %w[GLDRUB_TOM SLVRUB_TOM].each do |ticker|
      data = item(ticker, "currency", "CETS").merge("lot" => ticker == "GLDRUB_TOM" ? 1 : 100)
      expect(client).to receive(:call).with("InstrumentsService/GetInstrumentBy", { idType: "INSTRUMENT_ID_TYPE_UID", id: data["uid"] }).and_return("instrument" => data)
      expect(client.instrument(data["uid"])).to include(ticker: ticker, kind: "currency", class_code: "CETS", currency: "rub", lot: data["lot"], expiration_date: nil)
    end
  end

  it "rejects a direct UID request for an unsupported currency" do
    data = item("CNYRUB_TOM", "currency", "CETS")
    allow(client).to receive(:call).and_return("instrument" => data)
    expect { client.instrument(data["uid"]) }.to raise_error(TInvest::Error, /драгметаллы/)
  end

  it "requests exchange minute candles and excludes unfinished data without a rejected limit parameter" do
    from = Time.utc(2026, 9, 21, 10)
    quote = { "units" => "100", "nano" => 500_000_000 }
    candle = %w[open high low close].to_h { |field| [field, quote] }.merge("time" => from.iso8601, "isComplete" => true, "volume" => "123")
    expect(client).to receive(:call).with("MarketDataService/GetCandles", { instrumentId: "uid", from: from.iso8601, to: (from + 1.hour).iso8601, interval: "CANDLE_INTERVAL_1_MIN", candleSourceType: "CANDLE_SOURCE_EXCHANGE" }).and_return("candles" => [candle, candle.merge("isComplete" => false)])
    expect(client.minute_candles("uid", from: from, to: from + 1.hour)).to eq([{ time: from, volume: 123, open: 100.5.to_d, high: 100.5.to_d, low: 100.5.to_d, close: 100.5.to_d }])
  end
end
