require "rails_helper"
RSpec.describe LevelLifecycle do
  let(:instrument) { create_instrument }
  let!(:level) { create_strong_level(instrument, lower_price: 99, upper_price: 101, atr: 10, created_at: 30.days.ago) }
  def bars(prices)
    prices.each_with_index.map { |v,i| Candle.new(time: 20.days.ago.beginning_of_day + i.days, open: v, close: v, high: v + 0.5, low: v - 0.5) }
  end
  def run(rows, timeframe: "day")
    instrument.with_lock { described_class.call(instrument: instrument, timeframe: timeframe, candles: rows) }
  end
  it "records a close outside the zone followed by a failed breakout exactly once" do
    rows = bars([100, 104, 101])
    2.times { run(rows) }
    expect(MarketSignal.order(:id).pluck(:kind)).to eq(%w[confirmed failed_breakout])
    expect(level.reload).to have_attributes(status: "confirmed", side: "resistance", breakout: {})
    expect(MarketSignal.last.details).to include("upper" => "101.0", "buffer" => "1.0")
  end
  it "updates a weak zone lifecycle silently, including its changed role" do
    level.update!(assessment: { version: Detectors::Levels::VERSION, score: 15 })
    rows = bars([100, 104, 104])
    rows.last.low = 101
    run(rows)
    expect(MarketSignal.count).to eq(0)
    expect(level.reload).to have_attributes(status: 'confirmed', side: 'support')
    level.update!(assessment: { version: Detectors::Levels::VERSION, score: 40 })
    run(rows)
    expect(MarketSignal.count).to eq(0)
  end

  it "keeps the initial high grade for follow-ups even when the peer set changes" do
    rows = bars([100, 104, 101])
    run(rows.first(2))
    expect(level.reload.breakout['strength_grade']).to eq(3)
    instrument.price_levels.where.not(id: level.id).delete_all
    run(rows)
    expect(MarketSignal.order(:id).pluck(:kind)).to eq(%w[confirmed failed_breakout])
    expect(MarketSignal.last.details['strength_grade']).to eq(3)
  end

  it "finishes legacy scenarios with unknown initial strength without new alerts" do
    rows = bars([100, 104, 101])
    run(rows.first(2))
    level.update!(breakout: level.reload.breakout.except('strength_grade'))
    expect { run(rows) }.not_to change(MarketSignal, :count)
    expect(level.reload.status).to eq('confirmed')
  end

  it "does not alert for manual levels" do
    level.update!(source: 'manual')
    run(bars([100, 104, 101]))
    expect(MarketSignal.count).to eq(0)
  end

  it "uses frozen boundaries for a pending breakout" do
    rows = bars([100, 104])
    run(rows)
    level.update!(upper_price: 110)
    run(rows + [bars([100, 104, 103]).last])
    expect(MarketSignal.pluck(:kind)).to eq(["confirmed"])
    expect(level.reload.status).to eq("broken")
  end
  it "recognizes a retest on a subsequent candle and flips the role" do
    rows = bars([100, 104, 104])
    rows.last.low = 101
    run(rows)
    expect(MarketSignal.order(:id).pluck(:kind)).to eq(%w[confirmed retest])
    expect(level.reload).to have_attributes(status: "confirmed", side: "support")
  end
  it "holds for five subsequent candles before changing the role without a retest" do
    rows = bars([100, 104, 105, 106, 107, 108, 109])
    run(rows.first(6))
    expect(level.reload.status).to eq("broken")
    run(rows)
    expect(MarketSignal.order(:id).pluck(:kind)).to eq(%w[confirmed held_breakout])
    expect(level.reload.side).to eq("support")
  end
  it "handles downward support breaks symmetrically" do
    level.update!(side: "support")
    run(bars([100, 95, 99]))
    expect(MarketSignal.order(:id).pluck(:kind)).to eq(%w[confirmed failed_breakout])
    expect(level.reload.side).to eq("support")
  end
  it "ignores provisional zones and other timeframes" do
    level.update!(status: "candidate")
    run(bars([100, 104]))
    level.update!(status: "confirmed")
    run(bars([100, 104]), timeframe: "week")
    expect(MarketSignal.count).to eq(0)
  end
  it "does not backfill history for a newly registered zone" do
    level.update!(created_at: Time.current)
    run(bars([100, 104]))
    expect(MarketSignal.count).to eq(0)
  end
  it "advances the cursor while alerts are disabled and cancels pending scenarios" do
    run(bars([100, 104]))
    instrument.update!(breakout_enabled: false)
    run(bars([100, 104, 100]))
    expect(level.reload).to have_attributes(status: "confirmed", breakout: {})
    instrument.update!(breakout_enabled: true)
    run(bars([100, 104, 100]))
    expect(MarketSignal.pluck(:kind)).to eq(["confirmed"])
  end
end
