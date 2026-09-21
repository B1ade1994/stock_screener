require "rails_helper"

RSpec.describe RefreshHistoryJob, type: :job do
  let(:instrument) { create_instrument }
  let(:client) { instance_double(TInvest::Client) }
  let(:daily_candles) { [candle(3.days.ago, 99), candle(2.days.ago, 102)] }
  let(:weekly_candles) { [] }

  around do |example|
    travel_to(Time.zone.local(2026, 9, 19, 12)) { example.run }
  end

  before do
    allow(TInvest::Client).to receive(:new).and_return(client)
    allow(client).to receive(:candles).with(instrument.uid, "day").and_return(daily_candles)
    allow(client).to receive(:candles).with(instrument.uid, "week").and_return(weekly_candles)
  end

  def candle(time, close)
    quote = ->(value) { { "units" => value.to_s, "nano" => 0 } }
    {
      "time" => time.iso8601,
      "open" => quote.call(close),
      "high" => quote.call(close + 1),
      "low" => quote.call(close - 1),
      "close" => quote.call(close),
      "volume" => "100"
    }
  end

  context "with existing daily and weekly levels" do
    let(:weekly_candles) { [candle(14.days.ago, 98), candle(7.days.ago, 99)] }

    before do
      %w[day week].each do |timeframe|
        instrument.price_levels.create!(source: "manual", side: "resistance", timeframe: timeframe, price: 100, created_at: 10.days.ago)
      end
    end

    it "confirms the daily level once without confirming the weekly level" do
      expect { 2.times { described_class.perform_now(instrument.id) } }.to change(MarketSignal, :count).by(1)
      expect(MarketSignal.last).to have_attributes(kind: "confirmed", details: a_hash_including("timeframe" => "day"))
      expect(instrument.reload.history_synced_at).to eq(Time.current)
    end
  end

  it "does not backfill an old breakout for a newly created level" do
    instrument.price_levels.create!(source: "manual", side: "resistance", timeframe: "day", price: 100)
    expect { described_class.perform_now(instrument.id) }.not_to change(MarketSignal, :count)
  end
  it "preserves earlier reference history and gives real exchange candles priority at a matching timestamp" do
    reference = instrument.candles.create!(timeframe: "day", time: 5.days.ago, open: 90, high: 91, low: 89, close: 90,
      volume: nil, reference_volume: 1_000_000, data_source: "yahoo_spy")
    replacement = instrument.candles.create!(timeframe: "day", time: 3.days.ago, open: 90, high: 91, low: 89, close: 90,
      volume: nil, reference_volume: 1_000_000, data_source: "yahoo_spy")
    described_class.perform_now(instrument.id)
    expect(reference.reload).to have_attributes(data_source: "yahoo_spy", volume: nil)
    expect(replacement.reload).to have_attributes(data_source: "t_invest", volume: 100, reference_volume: nil, close: 99)
  end

  context "with spot gold" do
    let(:instrument) { create_instrument(ticker: "GLDRUB_TOM", kind: "currency", class_code: "CETS") }
    let(:weekly_candles) { [candle(7.days.ago, 98)] }

    it "loads both timeframes by UID and keeps prices and API volumes unchanged" do
      described_class.perform_now(instrument.id)
      expect(instrument.candles.group(:timeframe).count).to eq("day" => 2, "week" => 1)
      expect(instrument.candles.where(timeframe: "day").order(:time).last).to have_attributes(close: 102, volume: 100)
      expect(instrument.reload.history_error).to be_nil
      expect(instrument.history_synced_at).to eq(Time.current)
    end
  end

end
