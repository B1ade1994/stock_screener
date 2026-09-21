require "rails_helper"

RSpec.describe VolumeEpisode do
  let(:instrument) { create_instrument }
  let(:first_minute) { Time.zone.local(2026, 9, 21, 11, 59) }

  around { |example| travel_to(Time.zone.local(2026, 9, 21, 12, 0, 36)) { example.run } }

  def record(offset = 0, buy: 900, sell: 100, unknown: 0, open_price: "100", close_price: "101", instrument: self.instrument)
    bar = MarketMinute.new(time: first_minute + offset.minutes, session: "same-session")
    total = buy + sell + unknown
    details = { buy: buy, sell: sell, unknown: unknown, volume: total, baseline: 100.0, ratio: total / 100.0, buy_percent: buy * 100.0 / (buy + sell), open_price: open_price, close_price: close_price }
    described_class.record(instrument: instrument, bar: bar, details: details)
  end

  it "updates an episode and preserves each burst, first notification and price reference" do
    episode = record
    reaction = episode.reaction
    reference = reaction.reference_at
    created = episode.created_at
    travel 6.minutes
    expect { record(6, buy: 1900) }.not_to change(MarketSignal, :count)
    episode.reload
    expect(episode.details).to include("burst_count" => 2, "max_ratio" => 20.0, "price_open" => "100", "price_close" => "101", "price_direction" => "up")
    expect(episode.details.fetch("totals")).to include("volume" => 3000, "buy" => 2800, "sell" => 200)
    expect(episode.details.fetch("bursts").map { |b| b["volume"] }).to eq([1000, 2000])
    expect(episode.details.fetch("volume")).to eq(1000)
    expect(episode).to have_attributes(created_at: created, occurred_at: first_minute + 1.minute, last_occurred_at: first_minute + 7.minutes)
    expect(reaction.reload.reference_at).to eq(reference)
    expect(SignalReaction.count).to eq(1)
  end

  it "uses first open and last close to update the episode price direction" do
    episode = record(close_price: "102")
    travel 3.minutes
    record(3, open_price: "102", close_price: "99")
    expect(episode.reload.details).to include("price_open" => "100", "price_close" => "99", "price_direction" => "down")
    expect(episode.price_direction).to eq("down")
  end

  it "keeps the direction neutral when minute prices are unavailable" do
    episode = record(open_price: nil, close_price: nil)
    expect(episode.price_direction).to be_nil
  end

  it "does not extend the ten-minute window when bursts keep arriving" do
    first = record
    record(9)
    expect { record(10) }.to change(MarketSignal, :count).by(1)
    expect(first.reload.details.fetch("burst_count")).to eq(2)
  end

  it "separates directions and instruments, including unknown-dominated volume" do
    expect do
      record
      record(1, buy: 100, sell: 900)
      record(2, buy: 50, sell: 50, unknown: 900)
      record(3, instrument: create_instrument)
    end.to change(MarketSignal, :count).by(4)
    expect(instrument.signals.order(:id).pluck(:episode_direction)).to eq(%w[buy sell mixed])
  end

  it "is idempotent for both the first and later minutes, including out-of-order retries" do
    first = record
    record(3)
    record(1)
    2.times { record; record(3); record(1) }
    expect(MarketSignal.count).to eq(1)
    expect(first.reload.details.fetch("bursts").map { |b| b["time"] }).to eq([0, 1, 3].map { |m| (first_minute + (m + 1).minutes).iso8601 })
    expect(first.details.fetch("totals").fetch("volume")).to eq(3000)
    expect(first.last_occurred_at).to eq(first_minute + 4.minutes)
  end

  it "does not regroup legacy signals" do
    old = instrument.signals.create!(kind: "volume", title: "Legacy", event_key: "old", occurred_at: first_minute)
    expect { record }.to change(MarketSignal, :count).by(1)
    expect(old.reload.details).to eq({})
  end

  it "feeds detected anomalies into episodes without changing the detector threshold" do
    session = SecureRandom.uuid
    20.times do |index|
      instrument.market_minutes.create!(time: first_minute - (20 - index).minutes, session: session, buy: 80, sell: 20, complete: true)
    end
    bar = instrument.market_minutes.create!(time: first_minute, session: session, buy: 350, sell: 50, open_price: 100, close_price: 99, complete: true)
    SignalEvaluator.volume(instrument, bar)
    expect(instrument.signals.sole).to have_attributes(episode_direction: "buy")
    expect(instrument.signals.sole.details).to include("volume" => 400, "ratio" => 4.0)
    expect(instrument.signals.sole.price_direction).to eq("down")
  end
end
