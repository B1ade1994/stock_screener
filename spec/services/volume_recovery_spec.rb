require 'rails_helper'
RSpec.describe 'Volume baseline after reconnect' do
  let(:instrument) { create_instrument(volume_enabled: true) }
  around { |e| travel_to(Time.zone.local(2026,9,29,16,36,40)) { e.run } }
  def seed
    current = instrument.market_minutes.create!(time: Time.current.beginning_of_minute - 1.minute, complete: true,
      session: SecureRandom.uuid, buy: 400, sell: 40, unknown: 10, trades: 10, open_price: 100, close_price: 99, high_price: 100, low_price: 99)
    20.times do |i|
      instrument.reversal_minutes.create!(time: current.time - (20-i).minutes, open_price: 100, close_price: 100,
        high_price: 100.1, low_price: 99.9, volume: 100, data_source: 't_invest')
    end
    current
  end
  it 'uses continuous completed OHLCV totals without fabricating BUY/SELL before reconnect' do
    current = seed
    SignalEvaluator.volume(instrument, current)
    s = instrument.signals.where(kind:'volume').sole
    expect(s.details['bursts'].first).to include('baseline_source'=>'completed_ohlcv', 'baseline'=>100.0, 'buy'=>400, 'sell'=>40, 'unknown'=>10)
    expect(s.details['decision']).to include('baseline_source'=>'completed_ohlcv', 'passed'=>true)
    expect(instrument.market_minutes.count).to eq(1)
    SignalEvaluator.volume(instrument,current)
    expect(instrument.signals.where(kind: "volume").count).to eq(1)
    expect(instrument.signals.where(kind: VolumeFollowThrough::KIND).count).to eq(1)
  end
  it 'still refuses a missing baseline minute or an incomplete current minute' do
    current = seed
    missing = instrument.reversal_minutes.order(:time).first
    missing.destroy!
    SignalEvaluator.volume(instrument,current)
    expect(instrument.signals).to be_empty
    current.update!(complete:false)
    SignalEvaluator.volume(instrument,current)
    expect(instrument.signals).to be_empty
  end
end
