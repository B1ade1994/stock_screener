require "rails_helper"

RSpec.describe SpyHistoryBackfill do
  let(:as_of) { Date.new(2026, 9, 19) }
  let(:instrument) { create_instrument(ticker: "SP500F", kind: "futures", currency: "usd") }
  let(:dates) { (Date.new(2024, 9, 9)..Date.new(2026, 9, 18)).reject { |date| date.saturday? || date.sunday? } }
  let(:payload) do
    { "meta" => { "symbol" => "SPY", "currency" => "USD" },
      "timestamp" => dates.map { |date| Time.utc(date.year, date.month, date.day, 14).to_i },
      "indicators" => { "quote" => [{ "open" => dates.map { 99 }, "high" => dates.map { 102 },
        "low" => dates.map { 98 }, "close" => dates.map { 100 }, "volume" => dates.map { 10_000_000 } }] } }
  end

  before do
    dates.select { |date| date >= Date.new(2026, 8, 4) }.each do |date|
      instrument.candles.create!(timeframe: "day", time: Time.utc(date.year, date.month, date.day),
        open: 100, high: 103, low: 99, close: 100.1, volume: 300)
    end
    instrument.candles.create!(timeframe: "week", time: Time.utc(2026, 8, 3), open: 100, high: 103, low: 99, close: 100.1, volume: 1500)
  end

  def run_import(data = payload)
    described_class.call(instrument: instrument, payload: data, as_of: as_of)
  end

  it "extends the same instrument before launch, preserving real candles and keeping foreign volume separate" do
    native = instrument.candles.order(:id).map(&:attributes)
    instruments_count = Instrument.count
    expect { run_import }.not_to change(MarketSignal, :count)
    expect(Instrument.count).to eq(instruments_count)
    expect(instrument.candles.where(data_source: "t_invest").order(:id).map(&:attributes)).to eq(native)
    daily = instrument.candles.where(timeframe: "day", data_source: "yahoo_spy").order(:time)
    expect(daily.first.time.to_date).to eq(Date.new(2025, 9, 19))
    expect(daily.last.time.to_date).to eq(Date.new(2026, 8, 3))
    expect(daily.pluck(:volume).uniq).to eq([nil])
    expect(daily.first.reference_volume).to eq(10_000_000)
    expect(daily.first.close).to eq(100)
    weekly = instrument.candles.where(timeframe: "week", data_source: "yahoo_spy").order(:time)
    expect(weekly.first.time.to_date).to eq(Date.new(2024, 9, 16))
    expect(weekly.last.time.to_date).to eq(Date.new(2026, 7, 27))
    expect(weekly.last).to have_attributes(open: 99, high: 102, low: 98, close: 100, volume: nil, reference_volume: 50_000_000)
    expect { run_import }.not_to change(Candle, :count)
  end

  it "refuses a mismatched source before changing any candles" do
    payload["meta"]["symbol"] = "ES=F"
    expect { run_import }.to raise_error(ArgumentError, /Expected SPY/)
    expect(instrument.candles.where(data_source: "yahoo_spy")).to be_empty
  end

  it "rejects materially different prices at the join" do
    payload["indicators"]["quote"][0]["close"].map! { 101.99 }
    instrument.candles.where(timeframe: "day").update_all(close: 95)
    expect { run_import }.to raise_error(ArgumentError, /differs/)
    expect(instrument.candles.where(data_source: "yahoo_spy")).to be_empty
  end

  it "rejects malformed source candles without a partial import" do
    payload["indicators"]["quote"][0]["high"][100] = 90
    expect { run_import }.to raise_error(ArgumentError, /bounds/)
    expect(instrument.candles.where(data_source: "yahoo_spy")).to be_empty
  end
end
