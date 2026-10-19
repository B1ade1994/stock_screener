require 'rails_helper'

RSpec.describe DailySupportBounceResearch do
  let(:instrument) { create_instrument(kind: 'currency', ticker: 'GLDRUB_TOM', class_code: 'CETS', reversal_enabled: false) }
  let(:zone) { DailyRetestLevels::Zone.new(side: 'support', timeframe: 'week', lower_price: 100, upper_price: 110, touches: 2, assessment: { 'score' => 3, 'as_of' => '2026-09-28' }) }
  around { |example| travel_to(Time.zone.local(2026, 10, 13, 12)) { example.run } }
  before do
    allow(DailyRetestLevels).to receive(:new).with(instrument.id, 'day').and_return(instance_double(DailyRetestLevels, strong: [], push: nil))
    allow(DailyRetestLevels).to receive(:new).with(instrument.id, 'week').and_return(instance_double(DailyRetestLevels, strong: [zone], push: nil))
    allow(MarketIndicators).to receive(:atr) { |bars| Array.new(bars.size, 4) }
  end
  def candle(day, opening: 103, close: 104, low: 102, high: [opening, close].max, source: 't_invest')
    instrument.candles.create!(timeframe: 'day', time: Time.utc(2026, 10, day), data_source: source,
      open: opening, close: close, high: high, low: low, volume: 100)
  end
  def activate
    candle(12)
    described_class.call(instrument)
  end
  def candidate
    activate
    candle(13, opening: 103, close: 100, low: 99.5)
    travel_to Time.zone.local(2026, 10, 14, 12)
    described_class.call(instrument)
    instrument.signals.where(kind: described_class::KIND).sole
  end
  def confirm
    signal = candidate
    candle(14, opening: 101, close: 103, low: 100.5)
    travel_to Time.zone.local(2026, 10, 15, 12)
    described_class.call(instrument)
    signal.reload
  end

  it 'registers a silent candidate, confirms once on a later day, and measures only after confirmation registration' do
    signal = confirm
    expect(signal).to have_attributes(research_only: true, reversal_status: 'confirmed', confirmed_at: Time.current)
    expect(signal.details['setup']).to include('bars' => 1, 'status' => 'confirmed')
    expect(signal.details['stop'].to_d).to eq(99.1)
    expect(signal.reactions).to be_empty
    expect { described_class.call(instrument) }.not_to change(MarketSignal, :count)
    candle(15, opening: 103, close: 104, low: 102)
    travel_to Time.zone.local(2026, 10, 16, 12)
    described_class.call(instrument)
    expect(signal.reload.details['entry_price']).to be_nil
    candle(16, opening: 105, close: 106, low: 104)
    travel_to Time.zone.local(2026, 10, 17, 12)
    described_class.call(instrument)
    expect(signal.reload.details['entry_price'].to_d).to eq(105)
    expect(signal.details['outcomes']['1']['status']).to eq('measured')
    expect(DailySignalStatistics.call(date: signal.created_at.to_date, horizon: 5).sum { |r| r[:total] }).to eq(0)
  end
  it 'does not manufacture signals at first import, from pre-activation history or from the current day' do
    candle(12); candle(13, opening: 103, close: 100, low: 99.5)
    travel_to Time.zone.local(2026, 10, 14, 12)
    expect { described_class.call(instrument) }.not_to change(MarketSignal, :count)
    candle(14, opening: 101, close: 103, low: 100.5)
    described_class.call(instrument)
    expect(instrument.signals.where(kind: described_class::KIND)).to be_empty
    instrument.candles.find_by!(time: Time.utc(2026, 10, 14)).destroy!
    candle(14, opening: 103, close: 100, low: 99.5, source: 'yahoo_spy')
    travel_to Time.zone.local(2026, 10, 15, 12)
    described_class.call(instrument)
    expect(instrument.signals.where(kind: described_class::KIND)).to be_empty
  end
  it 'cancels a candidate on disabling and establishes a new baseline on re-enable' do
    signal = candidate
    instrument.update!(breakout_enabled: false)
    described_class.call(instrument)
    expect(signal.reload.reversal_status).to eq('cancelled')
    candle(14, opening: 101, close: 103, low: 100.5)
    travel_to Time.zone.local(2026, 10, 15, 12)
    instrument.update!(breakout_enabled: true)
    expect { described_class.call(instrument) }.not_to change(MarketSignal, :count)
    expect(signal.reload.confirmed_at).to be_nil
  end
  it 'expires a confirmation recovered with a newer bar and rejects gaps' do
    signal = candidate
    candle(14, opening: 101, close: 103, low: 100.5); candle(15)
    travel_to Time.zone.local(2026, 10, 16, 12)
    described_class.call(instrument)
    expect(signal.reload.reversal_status).to eq('expired')
    expect(signal.confirmed_at).to be_nil
    expect(signal.details).not_to have_key('outcomes')
  end
  it 'cancels missing daily continuity without interpreting later prices as confirmation' do
    signal = candidate
    candle(19)
    travel_to Time.zone.local(2026, 10, 20, 12)
    described_class.call(instrument)
    expect(signal.reload.reversal_status).to eq('cancelled')
    expect(signal.details['status_reason']).to include('разрыв')
  end
  it 'does not use unfinished weekly evidence and leaves shares untouched' do
    activate
    instrument.candles.create!(timeframe: 'week', time: Time.utc(2026, 10, 12), open: 100, close: 100, low: 99, high: 101, volume: 100)
    week = instance_double(DailyRetestLevels, strong: [], push: nil)
    allow(DailyRetestLevels).to receive(:new).with(instrument.id, 'week').and_return(week)
    expect(week).not_to receive(:push)
    candle(13, opening: 103, close: 100, low: 99.5)
    travel_to Time.zone.local(2026, 10, 14, 12)
    described_class.call(instrument)
    expect(instrument.signals.where(kind: described_class::KIND)).to be_empty
    share = create_instrument
    expect { described_class.call(share) }.not_to change { share.reload.attributes }
  end
  it 'keeps confirmation context explicitly countertrend without vetoing the support setup' do
    allow(TechnicalContext).to receive(:trend).and_return('direction' => 'down')
    expect(confirm.details['confirmation_context']).to include('direction' => 'down')
  end
end
