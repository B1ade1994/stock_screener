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
end
