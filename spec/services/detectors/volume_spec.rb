require "rails_helper"

RSpec.describe Detectors::Volume do
  subject(:result) do
    described_class.evaluate(current: current, history: history, multiplier: 3, minimum: 10)
  end

  let(:start_time) { Time.utc(2026, 9, 18, 10) }
  let(:history) do
    20.times.map do |index|
      MarketMinute.new(time: start_time + index * 60, session: "a", buy: 60, sell: 40, unknown: 0, complete: true)
    end
  end
  let(:current) do
    MarketMinute.new(time: start_time + 20 * 60, session: "a", buy: 300, sell: 80, unknown: 20, complete: true)
  end

  it "uses prior minutes only and keeps unknown direction separate" do
    expect(result).to include(ratio: 4.0, unknown: 20, buy_percent: 78.9)
  end

  it "does not signal with a partial baseline" do
    history.first.complete = false
    expect(result).to be_nil
  end

  it "does not combine minutes from different connections" do
    history.first.session = "old"
    expect(result).to be_nil
  end

  it "does not signal across a missing minute" do
    history.first.time -= 60
    expect(result).to be_nil
  end

  it "does not divide by a zero baseline" do
    history.each { |bar| bar.assign_attributes(buy: 0, sell: 0) }
    expect(result).to be_nil
  end

  it "waits for the complete baseline" do
    history.pop
    expect(result).to be_nil
  end

  it "requires the absolute minimum even when the relative threshold is exceeded" do
    history.each { |bar| bar.assign_attributes(buy: 1, sell: 0) }
    current.assign_attributes(buy: 9, sell: 0, unknown: 0)
    expect(result).to be_nil
  end
end
