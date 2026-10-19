require "rails_helper"

RSpec.describe SignalReactionRecorder do
  let(:instrument) { create_instrument(last_price: 900) }
  let(:signal) { instrument.signals.create!(kind: "volume", title: "Volume", event_key: "reaction", occurred_at: 10.minutes.ago) }
  let(:reaction) { signal.reaction }
  let(:reference) { reaction.reference_at }
  let(:candles) do
    61.times.map do |index|
      { time: reference + index.minutes, open: 100.to_d, close: (100 + (index + 1) / 10.0).to_d, high: (100 + (index + 1) / 10.0).to_d, low: 99.to_d }
    end
  end

  around { |example| travel_to(Time.zone.local(2026, 9, 21, 12, 0, 36)) { example.run } }

  it "anchors to the minute after detection, not the older market time or last quote" do
    expect(reference).to eq(Time.zone.local(2026, 9, 21, 12, 1))
    described_class.call(reaction: reaction, candles: candles, now: reference + 5.minutes + 30.seconds)
    expect(reaction.reload.reference_price).to eq(100)
    expect(reaction.results.keys).to eq(["5"])
    expect(reaction.results.fetch("5")).to include("status" => "measured", "change_percent" => 0.5, "high_percent" => 0.5, "low_percent" => -1.0, "candles" => 5)
    expect(reaction.next_check_at).to eq(reference + 15.minutes + 30.seconds)
  end

  it "waits for the horizon and candle settlement, even if the API supplied future candles" do
    described_class.call(reaction: reaction, candles: candles, now: reference + 5.minutes + 29.seconds)
    expect(reaction.reload.results).to eq({})
  end

  it "catches up after downtime, persists all horizons and never rewrites measured results" do
    described_class.call(reaction: reaction, candles: candles, now: reference + 2.hours)
    expect(reaction.reload.results.transform_values { |r| r["change_percent"] }).to eq("5" => 0.5, "15" => 1.5, "30" => 3.0, "60" => 6.0)
    expect(reaction.next_check_at).to be_nil
    original = reaction.results.deep_dup
    described_class.call(reaction: reaction, candles: [], now: reference + 3.hours)
    expect(reaction.reload.results).to eq(original)
  end

  it "retries missing endpoint data, then marks it unavailable instead of using a nearby candle" do
    missing = candles.reject { |c| c[:time] == reference + 4.minutes }
    described_class.call(reaction: reaction, candles: missing, now: reference + 6.minutes)
    expect(reaction.reload.results).not_to have_key("5")
    described_class.call(reaction: reaction, candles: missing, now: reference + 16.minutes)
    expect(reaction.reload.results.fetch("5")).to include("status" => "unavailable")
    expect(reaction.results.fetch("15")).to include("status" => "measured", "candles" => 14)
  end

  it "records a missing start only for elapsed horizons and schedules recovery without inventing a price" do
    described_class.call(reaction: reaction, candles: candles.drop(1), now: reference + 10.minutes)
    expect(reaction.reload.reference_price).to be_nil
    expect(reaction.results.values.map { |r| r["status"] }.uniq).to eq(["unavailable"])
    expect(reaction.results.keys).to eq(['5'])
    expect(reaction.results['5']['quality_code']).to eq('missing_start')
    expect(reaction.next_check_at).to eq(reference + 15.minutes)
  end

  it "tolerates deletion while an API request was in progress" do
    saved = reaction
    signal.destroy!
    expect { described_class.call(reaction: saved, candles: [], now: Time.current) }.not_to raise_error
    expect(SignalReaction.exists?(saved.id)).to be false
  end

  it "cascades observations when the instrument deletes its signals in bulk" do
    reaction
    expect { instrument.destroy! }.to change(SignalReaction, :count).by(-1)
  end
  it "freezes a control trend using only the five candles strictly before the reference" do
    prior = (1..5).map { |offset| { time: reference - offset.minutes, open: 100.to_d, close: 99.to_d, high: 101.to_d, low: 98.to_d } }
    described_class.call(reaction: reaction, candles: prior + candles, now: reference + 6.minutes)
    expect(reaction.reload.baseline).to include('status' => 'measured', 'direction' => 'down', 'change_percent' => -1.0)
    described_class.call(reaction: reaction, candles: candles, now: reference + 16.minutes)
    expect(reaction.reload.baseline['direction']).to eq('down')
  end

  it "does not infer a control trend across missing preceding minutes" do
    prior = (1..4).map { |offset| { time: reference - offset.minutes, open: 100.to_d, close: 99.to_d, high: 101.to_d, low: 98.to_d } }
    described_class.call(reaction: reaction, candles: prior + candles, now: reference + 6.minutes)
    expect(reaction.reload.baseline['status']).to eq('unavailable')
    expect(reaction.results['5']['status']).to eq('measured')
  end

  it 'recovers an internal gap while preserving already complete results' do
    missing = candles.reject { |c| c[:time] == reference + 7.minutes }
    described_class.call(reaction: reaction, candles: missing, now: reference + 16.minutes)
    original = reaction.reload.results['5'].deep_dup
    expect(reaction.results['15']).to include('quality_code' => 'missing_minutes', 'missing_count' => 1,
      'missing_at' => [(reference + 7.minutes).iso8601], 'candles' => 14)
    expect(reaction.next_check_at).to be_present
    described_class.call(reaction: reaction, candles: candles, now: reference + 21.minutes)
    expect(reaction.reload.results['15']).to include('candles' => 15, 'recovered_at' => (reference + 21.minutes).iso8601)
    expect(reaction.results['15']).not_to have_key('quality_code')
    expect(reaction.results['5']).to eq(original)
  end

  it 'recovers an unavailable endpoint and never degrades an already observed partial window' do
    missing = candles.reject { |c| c[:time] == reference + 4.minutes }
    described_class.call(reaction: reaction, candles: missing, now: reference + 16.minutes)
    expect(reaction.reload.results['5']['quality_code']).to eq('missing_end')
    described_class.call(reaction: reaction, candles: missing.drop(2), now: reference + 21.minutes)
    expect(reaction.reload.results['15']['candles']).to eq(14)
    described_class.call(reaction: reaction, candles: candles, now: reference + 22.minutes)
    expect(reaction.reload.results['5']).to include('status' => 'measured', 'candles' => 5, 'recovered_at' => (reference + 22.minutes).iso8601)
  end

  it 'stops recovery after its deadline and keeps the partial observation for quality reporting' do
    missing = candles.reject { |c| c[:time] == reference + 7.minutes }
    described_class.call(reaction: reaction, candles: missing, now: reference + 2.hours)
    partial = reaction.reload.results['15'].deep_dup
    described_class.call(reaction: reaction, candles: candles, now: reference + 26.hours)
    expect(reaction.reload.results['15']).to eq(partial)
    expect(reaction.next_check_at).to be_nil
  end

end
