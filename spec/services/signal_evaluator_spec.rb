require "rails_helper"

RSpec.describe SignalEvaluator do
  let(:instrument) { create_instrument }

  around do |example|
    travel_to(Time.zone.local(2026, 9, 19, 12)) { example.run }
  end

  it "does not create a historical crossing on the first tick" do
    instrument.price_levels.create!(price: 100, side: "resistance", timeframe: "week", source: "manual")
    expect { described_class.crossings(instrument, 110, Time.current) }.not_to change(MarketSignal, :count)
  end

  context "with a fresh price below resistance" do
    before do
      instrument.price_levels.create!(price: 100, side: "resistance", timeframe: "day", source: "manual")
      instrument.update!(last_price: 99, last_trade_at: 10.seconds.ago)
    end

    it "applies a cooldown to repeated crossing events" do
      expect { 2.times { described_class.crossings(instrument, 101, Time.current) } }.to change(MarketSignal, :count).by(1)
    end

    it "respects the breakout checkbox without relying on a previous cooldown" do
      instrument.update!(breakout_enabled: false)
      expect { described_class.crossings(instrument, 101, Time.current) }.not_to change(MarketSignal, :count)
    end
  end
end
