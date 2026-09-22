require "rails_helper"

RSpec.describe SignalEvaluator do
  let(:instrument) { create_instrument }

  around do |example|
    travel_to(Time.zone.local(2026, 9, 19, 12)) { example.run }
  end

  it "does not create a historical crossing on the first tick" do
    create_strong_level(instrument, timeframe: "week")
    expect { described_class.crossings(instrument, 110, Time.current) }.not_to change(MarketSignal, :count)
  end

  context "with a fresh price below resistance" do
    before do
      create_strong_level(instrument)
      instrument.update!(last_price: 99, last_trade_at: 10.seconds.ago)
    end

    it "applies a cooldown to repeated crossing events" do
      expect { 2.times { described_class.crossings(instrument, 101, Time.current) } }.to change(MarketSignal, :count).by(1)
    end

    it "ignores low, medium, ungraded and manual levels without consuming their cooldown" do
      level = instrument.price_levels.find_by(price: 100)
      [{ assessment: { version: Detectors::Levels::VERSION, score: 5 } },
       { assessment: { version: Detectors::Levels::VERSION, score: 15 } },
       { assessment: {} }, { source: 'manual' }].each do |attributes|
        level.update!(attributes)
        expect { described_class.crossings(instrument, 101, Time.current) }.not_to change(MarketSignal, :count)
        expect(level.reload.last_alert_at).to be_nil
      end
    end

    it "uses the current strength and does not depend on the chart eye" do
      level = instrument.price_levels.find_by(price: 100)
      level.update!(chart_visible: false)
      described_class.crossings(instrument, 101, Time.current)
      expect(MarketSignal.last.details).to include('strength_grade' => 3, 'level_id' => level.id)
    end

    it "does not assign high strength without enough comparable levels" do
      instrument.price_levels.where('price > ?', 100).first.destroy!
      expect { described_class.crossings(instrument, 101, Time.current) }.not_to change(MarketSignal, :count)
    end

    it "respects the breakout checkbox without relying on a previous cooldown" do
      instrument.update!(breakout_enabled: false)
      expect { described_class.crossings(instrument, 101, Time.current) }.not_to change(MarketSignal, :count)
    end
  end
end
