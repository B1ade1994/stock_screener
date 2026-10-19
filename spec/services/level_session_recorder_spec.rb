require 'rails_helper'
RSpec.describe LevelSessionRecorder do
  let(:instrument) { create_instrument }
  around { |e| travel_to(Time.zone.local(2026,9,28,12)) { e.run } }
  def signal
    instrument.signals.create!(kind:'crossing',title:'Level',event_key:SecureRandom.uuid,occurred_at:Time.current,details:{side:'support'})
  end
  def candle(date,price,source='t_invest')
    instrument.candles.create!(timeframe:'day',time:Time.zone.parse(date+' 03:00'),open:100,close:price,high:[100,price].max,low:[100,price].min,volume:10,data_source:source)
  end
  it 'counts completed exchange daily candles, not calendar days or proxy history' do
    s=signal;r=s.reaction;r.update!(reference_at:Time.zone.local(2026,9,24,12),reference_price:100)
    candle('2026-09-24',101);candle('2026-09-25',99);candle('2026-09-26',200,'yahoo_spy');candle('2026-09-28',95)
    described_class.call(instrument:instrument)
    expect(r.reload.session_results.keys).to eq(['1'])
    travel_to Time.zone.local(2026,9,29,12)
    described_class.call(instrument:instrument)
    expect(r.reload.session_results['3']).to include('change_percent'=>-5.0)
    expect(r.session_results).not_to have_key('5')
    summary=described_class.statistics(Date.new(2026,9,28)).find { |x| x[:horizon]==3 }
    expect(summary).to include(measured:1,positive:1,mean:5.0)
  end
  it 'does not invent an entry price and preserves already recorded results' do
    r=signal.reaction;r.update!(next_check_at:nil)
    described_class.call(instrument:instrument)
    expect(r.reload.session_results.values.map { |x| x['status'] }).to eq(['unavailable']*3)
  end
end
