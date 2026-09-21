require "rails_helper"

RSpec.describe RefreshSignalReactionsJob, type: :job do
  let(:client) { instance_double(TInvest::Client) }
  let(:instrument) { create_instrument }

  around { |example| travel_to(Time.zone.local(2026, 9, 21, 12, 0, 36)) { example.run } }
  before { allow(TInvest::Client).to receive(:new).and_return(client) }

  def event(instrument = self.instrument)
    instrument.signals.create!(kind: "volume", title: "Test", event_key: SecureRandom.uuid, occurred_at: Time.current)
  end

  def candles(time)
    60.times.map { |n| { time: time + n.minutes, open: 100.to_d, close: 101.to_d, high: 102.to_d, low: 99.to_d } }
  end

  it "batches episodes of one instrument and resumes elapsed horizons after a worker restart" do
    first = event.reaction
    travel 1.minute
    second = event.reaction
    travel 20.minutes
    expect(client).to receive(:minute_candles).once.with(instrument.uid, from: first.reference_at, to: Time.current - 30.seconds).and_return(candles(first.reference_at))
    described_class.perform_now
    [first, second].each { |r| expect(r.reload.results.keys).to eq(%w[5 15]) }
  end

  it "does not query the API until a horizon is due" do
    event
    expect(client).not_to receive(:minute_candles)
    described_class.perform_now
  end

  it "isolates an API failure and schedules a retry without interrupting another instrument" do
    first = event.reaction
    other = create_instrument
    second = event(other).reaction
    travel 10.minutes
    allow(client).to receive(:minute_candles).with(instrument.uid, anything).and_raise(TInvest::Error, "Т-Инвестиции: HTTP 503")
    allow(client).to receive(:minute_candles).with(other.uid, anything).and_return(candles(second.reference_at))
    described_class.perform_now
    expect(first.reload.results).to eq({})
    expect(first.last_error).to include("503")
    expect(first.next_check_at).to eq(2.minutes.from_now)
    expect(second.reload.results.fetch("5")).to include("status" => "measured")
  end

  it "stops retrying unavailable API data after a day" do
    reaction = event.reaction
    travel 25.hours
    allow(client).to receive(:minute_candles).and_raise(TInvest::Error, "Т-Инвестиции: HTTP 503")
    described_class.perform_now
    expect(reaction.reload.next_check_at).to be_nil
    expect(reaction.results.values.map { |r| r["status"] }.uniq).to eq(["unavailable"])
  end
end
