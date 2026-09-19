require "rails_helper"
RSpec.describe MarketIndicators do
  def bars(values)
    values.map { |v| Candle.new(close: v, high: v + 1, low: v - 1) }
  end
  it "seeds EMA with SMA and requires a full warmup" do
    expect(described_class.ema(bars([1, 2, 3, 4, 5]), 3)).to eq([nil, nil, 2.0, 3.0, 4.0])
    expect(described_class.ema(bars([1, 2]), 3)).to eq([nil, nil])
  end
  it "includes price gaps in Wilder ATR" do
    values = described_class.atr(bars([10, 10, 20, 20]), 3)
    expect(values[2]).to eq(5)
    expect(values[3]).to eq(4)
  end
  it "never changes past values when future candles arrive" do
    rows = bars((1..50).to_a)
    expect(described_class.atr(rows).first(30)).to eq(described_class.atr(rows.first(30)))
    expect(described_class.ema(rows, 20).first(30)).to eq(described_class.ema(rows.first(30), 20))
  end
end
