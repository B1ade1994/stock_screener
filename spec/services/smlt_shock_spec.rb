require 'rails_helper'

RSpec.describe 'SMLT shock regression, 29 September 2026' do
  let(:instrument) { create_instrument(ticker:'SMLT',reversal_enabled:true,breakout_enabled:true) }
  around { |e| travel_to(Time.zone.local(2026,9,29,16,30)) { e.run } }
  before do
    # Official closed candles. All are preloaded deliberately: the service must
    # select only minutes available at the simulated decision time.
    JSON.parse(Rails.root.join('spec/fixtures/smlt_shock_20260929.json').read).each do |b|
      instrument.reversal_minutes.create!(time: Time.parse(b.fetch('time')), data_source:'t_invest', volume:b.fetch('volume'),
        open_price:b.fetch('open'),high_price:b.fetch('high'),low_price:b.fetch('low'),close_price:b.fetch('close'))
    end
  end
  def tick(minute)
    travel_to Time.zone.local(2026,9,29,16,minute,36)
    DirectionalHints.call(instrument, collect: true)
  end
  it 'keeps the first failed attempt and creates a second candidate only after the fresh low' do
    (30..41).each { |m| tick(m) }
    expect(instrument.signals).to be_empty
    tick(42)
    first = instrument.signals.where(experiment: 'directional_v1').sole
    expect(first.details['extreme'].to_d).to eq(230)
    expect(first.reversal_status).to eq('possible')
    tick(43)
    expect(first.reload.reversal_status).to eq('cancelled')
    expect(first.confirmed_at).to be_nil
    tick(44);tick(45)
    expect(instrument.signals.where(experiment: 'directional_v1').count).to eq(1)
    tick(46)
    second = instrument.signals.where(experiment: 'directional_v1').order(:id).last
    expect(second.details['extreme'].to_d).to eq(227.4)
    expect(second.details['decision_price'].to_d).to eq(232.6)
    tick(47);tick(48)
    expect(second.reload.reversal_status).to eq('confirmed')
    expect(second.confirmation_reaction.reference_at.in_time_zone.strftime('%H:%M')).to eq('16:49')
    expect(instrument.signals.visible).to be_empty
    tick(48)
    expect(instrument.signals.where(experiment: 'directional_v1').count).to eq(2)
  end

  it 'records an opposite shock as a conflict rather than letting an earlier short hide the rebound' do
    travel_to Time.zone.local(2026,9,29,16,36,56)
    instrument.signals.create!(kind:'crossing',event_key:'smlt-level',occurred_at:Time.current,title:'Пересечение',
      details:{side:'support',strength_grade:3,lower:'237.470768685',upper:'258.497710758',buffer:'1.6357347671'})
    (38..42).each { |m| tick(m) }
    short = instrument.signals.where(kind:'directional_hint', experiment:'directional_v1').find { |s| s.details['direction']=='down' }
    expect(short).to be_present
    expect(short.reload.reversal_status).to eq('cancelled')
    expect(short.details['status_reason']).to include('конфликт сценариев')
    expect(instrument.signals.where(kind:'directional_hint', experiment:'directional_v1').where("details ->> 'monitoring' = 'true'").sole.details['direction']).to eq('up')
  end
end
