require "rails_helper"
RSpec.describe Detectors::Levels do
  def history
    dates = (Date.new(2026, 1, 1)..Date.new(2026, 4, 1)).reject { |d| d.saturday? || d.sunday? }.first(45)
    dates.map { |d| Candle.new(time: d.in_time_zone, open: 95, close: 95, high: 100, low: 90, volume: 100) }.tap do |rows|
      rows[25].assign_attributes(high: 110, volume: 200)
      rows[33].assign_attributes(high: 111, volume: 400)
    end
  end
  it "groups independent reactions farther apart than 0.3% using ATR zones" do
    zone = described_class.candidates(history).sole
    expect(zone).to include(side: "resistance", status: "confirmed", touches: 2)
    expect(zone[:lower_price]).to be < 110
    expect(zone[:upper_price]).to be > 111
    expect(zone[:assessment]).to include(version: 2, relative_volume: 3.0, volume_samples: 2)
  end
  it "keeps a strong single reaction provisional until the next approach is confirmed" do
    zone = described_class.candidates(history.first(35)).sole
    expect(zone).to include(status: "candidate", touches: 1)
    expect(described_class.candidates(history.first(36)).sole).to include(status: "confirmed", touches: 2)
  end
  it "does not fabricate ATR from insufficient history" do
    expect(described_class.candidates(history.first(13))).to be_empty
  end
  it "requires departure from the zone between approaches" do
    rows = history
    (28..32).each { |i| rows[i].assign_attributes(open: 104, close: 104, high: 105, low: 103) }
    rows[26].close = rows[27].close = 104
    expect(described_class.candidates(rows).map { |c| c[:touches] }).not_to include(2)
  end
  it "reduces the score when evidence ages" do
    rows = history
    score = described_class.candidates(rows).sole[:assessment][:score]
    20.times { rows << Candle.new(time: rows.last.time + 1.day, open: 95, close: 95, high: 100, low: 90, volume: 100) }
    expect(described_class.candidates(rows).sole[:assessment][:score]).to be < score
  end
  it "does not invent relative volume when the comparable history is absent" do
    rows = history
    rows[25].volume = rows[33].volume = nil
    expect(described_class.candidates(rows).sole[:assessment]).to include(relative_volume: nil, volume_samples: 0)
  end
  it "normalizes day volume by weekday/weekend group without future samples" do
    dates = (Date.new(2025, 1, 1)..Date.new(2025, 5, 1)).to_a
    rows = dates.map { |d| Candle.new(time: d.in_time_zone, volume: d.saturday? || d.sunday? ? 10 : 1000) }
    index = dates.index(Date.new(2025, 4, 6))
    rows[index].volume = 50
    rows[index + 1].volume = 999999
    expect(described_class.relative_volume(rows, index)).to eq(5)
    expect(described_class.relative_volume(rows, 4)).to be_nil
    expect(described_class.relative_volume(rows, index, timeframe: "week")).to eq(0.05)
  end
  it "rejects zero or incomplete volume baselines" do
    rows = history
    rows.first(25).each { |c| c.volume = 0 }
    expect(described_class.relative_volume(rows, 25)).to be_nil
    rows[10].volume = nil
    expect(described_class.relative_volume(rows, 25)).to be_nil
  end
  it "crosses the outside of the zone plus its buffer, not its center" do
    expect(described_class.crossed?(side: "resistance", price: 100, lower: 98, upper: 102, buffer: 2, previous: 100, current: 103)).to be false
    expect(described_class.crossed?(side: "resistance", price: 100, lower: 98, upper: 102, buffer: 2, previous: 100, current: 105)).to be true
    expect(described_class.crossed?(side: "support", price: 100, lower: 98, upper: 102, buffer: 2, previous: 100, current: 95)).to be true
    expect(described_class.crossed?(side: "support", price: 100, previous: nil, current: 90)).to be false
    expect(described_class.crossed?(side: "resistance", price: 100, previous: 101, current: 102)).to be false
  end
end
