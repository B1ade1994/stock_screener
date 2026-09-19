require "rails_helper"

RSpec.describe Detectors::Levels do
  describe ".crossed?" do
    it "detects resistance crossed upwards and support crossed downwards" do
      expect(described_class.crossed?(side: "resistance", price: 100, previous: 99, current: 101)).to be true
      expect(described_class.crossed?(side: "support", price: 100, previous: 101, current: 99)).to be true
    end

    it "requires a move beyond the tolerance" do
      expect(described_class.crossed?(side: "resistance", price: 100, previous: 99, current: 100.05)).to be false
    end

    it "does not treat staying above a level as another crossing" do
      expect(described_class.crossed?(side: "resistance", price: 100, previous: 101, current: 102)).to be false
    end

    it "requires a previous price" do
      expect(described_class.crossed?(side: "support", price: 100, previous: nil, current: 99)).to be false
    end
  end

  describe ".candidates" do
    let(:candles) do
      [8, 9, 10, 9, 8, 9, 10.01, 9, 8].map { |value| Candle.new(high: value, low: value - 1) }
    end

    it "groups repeated swings confirmed by later candles" do
      expect(described_class.candidates(candles)).to contain_exactly(
        a_hash_including(side: "resistance", touches: 2)
      )
    end

    it "does not use a swing before the later candles arrive" do
      expect(described_class.candidates(candles.first(7))).to be_empty
    end
  end
end
