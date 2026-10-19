require 'rails_helper'
RSpec.describe 'Grouped crossings' do
  let(:instrument) { create_instrument(last_price: 99, last_trade_at: 10.seconds.ago) }
  around { |e| travel_to(Time.zone.local(2026,9,25,12)) { e.run } }
  def level(lo, hi, side: 'resistance', timeframe: 'day')
    instrument.price_levels.create!(price: (lo+hi)/2.0, lower_price: lo, upper_price: hi, side: side, timeframe: timeframe, source: 'automatic')
  end
  before { allow_any_instance_of(LevelStrength).to receive(:call).and_return(double(grade: 3)) }
  it 'groups overlapping strong daily/weekly zones, preserves every level and applies cooldown to all' do
    first = level(99,100); second = level(99.5,100.5,timeframe: 'week')
    2.times { SignalEvaluator.crossings(instrument,102,Time.current) }
    signal = instrument.signals.sole
    expect(signal.details['levels'].map { |l| l['id'] }).to contain_exactly(first.id,second.id)
    expect(signal.details).to include('lower'=>'99.0','upper'=>'100.5')
    expect([first,second].map { |l| l.reload.last_alert_at }).to all(eq(Time.current))
    expect(SignalReaction.count).to eq(1)
  end
  it 'keeps non-overlapping zones independent' do
    level(99,100); level(101,102)
    SignalEvaluator.crossings(instrument,104,Time.current)
    expect(instrument.signals.count).to eq(2)
  end
  it 'rolls back all event creation and cooldowns on a failure' do
    first=level(99,100); level(101,102)
    allow(MarketSignal).to receive(:create!).and_wrap_original do |method, **args|
      raise 'fail second' if MarketSignal.count == 1
      method.call(**args)
    end
    expect { SignalEvaluator.crossings(instrument,104,Time.current) }.to raise_error('fail second')
    expect(MarketSignal.count).to eq(0)
    expect(first.reload.last_alert_at).to be_nil
  end
end
