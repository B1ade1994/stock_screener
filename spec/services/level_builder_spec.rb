require "rails_helper"
RSpec.describe LevelBuilder do
  let(:instrument) { create_instrument }
  let(:candles) { [Candle.new(time: 1.day.ago)] }
  let(:candidate) { { price: 110, lower_price: 107, upper_price: 113, atr: 10, side: "resistance", status: "confirmed", touches: 2, assessment: { version: 2, origin_side: "resistance", score: 3 } } }
  before { allow(Detectors::Levels).to receive(:candidates).and_return([candidate]) }
  def rebuild
    described_class.call(instrument: instrument, timeframe: "day", candles: candles)
  end
  it "creates a zone idempotently without historical signals" do
    expect { 2.times { rebuild } }.to change(PriceLevel, :count).by(1).and change(MarketSignal, :count).by(0)
    expect(PriceLevel.last.evaluated_at).to eq(candles.last.time)
  end
  it "updates overlapping boundaries but does not reactivate a user-hidden level" do
    level = instrument.price_levels.create!(price: 109, timeframe: "day", side: "resistance", source: "automatic", active: false)
    rebuild
    expect(level.reload).to have_attributes(price: 110, lower_price: 107, upper_price: 113, active: false, touches: 2)
    expect(instrument.price_levels.count).to eq(1)
  end
  it "archives obsolete automatic zones and preserves manual levels" do
    old = instrument.price_levels.create!(price: 150, timeframe: "day", side: "resistance", source: "automatic")
    manual = instrument.price_levels.create!(price: 150, timeframe: "day", side: "resistance", source: "manual")
    rebuild
    expect(old.reload).to have_attributes(active: false, status: "archived")
    expect(manual.reload).to have_attributes(active: true, price: 150)
  end
  it "freezes an open breakout even if it falls out of the ranked candidates" do
    level = instrument.price_levels.create!(price: 109, timeframe: "day", side: "resistance", source: "automatic", status: "broken", breakout: { lower: 108, upper: 110 })
    rebuild
    expect(level.reload).to have_attributes(price: 109, status: "broken", active: true)
    allow(Detectors::Levels).to receive(:candidates).and_return([])
    rebuild
    expect(level.reload.active?).to be true
  end
  it "preserves a role change when matching the original resistance evidence" do
    level = instrument.price_levels.create!(price: 109, timeframe: "day", side: "support", source: "automatic", assessment: { origin_side: "resistance", role_changed_at: Time.current.iso8601 })
    rebuild
    expect(level.reload.side).to eq("support")
    expect(instrument.price_levels.count).to eq(1)
  end
  it "does not calculate distance without a reference price" do
    level = PriceLevel.new(price: 120)
    expect(level.distance_percent(nil)).to be_nil
    expect(level.distance_percent(0)).to be_nil
    expect(level.distance_percent(100)).to eq(20)
  end
end
