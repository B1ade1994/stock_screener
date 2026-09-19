require "rails_helper"

RSpec.describe LevelStrength do
  let(:instrument) { create_instrument }
  def zone(score, **attributes)
    PriceLevel.new({ instrument: instrument, source: "automatic", timeframe: "day", side: "resistance", price: 100,
      touches: 2, assessment: { version: Detectors::Levels::VERSION, score: score } }.merge(attributes))
  end

  it "grades comparable confirmed zones by rank" do
    levels = [zone(1), zone(2), zone(5)]
    evaluator = described_class.new(levels)
    expect(levels.map { |level| evaluator.call(level).label }).to eq(%w[Низкая Средняя Высокая])
    expect(evaluator.call(levels.last).explanation).to include("3 подтверждённых зон 1D", "Не вероятность")
  end

  it "does not equate an isolated zone with high strength" do
    levels = [zone(5), zone(10)]
    expect(described_class.new(levels).call(levels.last)).to have_attributes(label: "Мало уровней", grade: nil)
  end

  it "keeps equal scores equal and rates a fully tied group as medium" do
    levels = [zone(1), zone(2), zone(2), zone(3)]
    evaluator = described_class.new(levels)
    expect(evaluator.call(levels[1]).grade).to eq(evaluator.call(levels[2]).grade)
    tied = Array.new(3) { zone(2) }
    expect(tied.map { |level| described_class.new(tied).call(level).grade }).to eq([2, 2, 2])
  end

  it "separates instruments and timeframes" do
    levels = [zone(1), zone(2), zone(3)]
    weekly = zone(100, timeframe: "week")
    other = zone(100, instrument: create_instrument)
    evaluator = described_class.new(levels + [weekly, other])
    expect(evaluator.call(levels.last).grade).to eq(3)
    expect(evaluator.call(weekly).label).to eq("Мало уровней")
    expect(evaluator.call(other).label).to eq("Мало уровней")
  end

  it "keeps preliminary, broken, manual and inactive zones out of the ranking" do
    levels = [zone(1), zone(2), zone(3)]
    excluded = [zone(100, status: "candidate", touches: 1), zone(100, status: "broken"), zone(100, source: "manual"), zone(100, active: false)]
    evaluator = described_class.new(levels + excluded)
    expect(levels.map { |level| evaluator.call(level).grade }).to eq([1, 2, 3])
    expect(excluded.map { |level| evaluator.call(level).label }).to eq(["Предварительная", "Пробой", "Без оценки", "Неактивен"])
  end

  it "does not grade legacy, missing or invalid assessment" do
    levels = [zone(nil), zone("bad"), zone(-1), zone(10, assessment: { score: 10, version: 1 }), zone(10, touches: 1)]
    evaluator = described_class.new(levels)
    expect(levels.map { |level| evaluator.call(level).label }).to all(eq("Нет оценки"))
  end

  it "includes chart-hidden zones in the comparison" do
    levels = [zone(1), zone(2), zone(3, chart_visible: false)]
    expect(described_class.new(levels).call(levels.last).grade).to eq(3)
  end
end
