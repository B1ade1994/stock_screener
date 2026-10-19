require 'rails_helper'
RSpec.describe 'Quality comparison statistics' do
  let(:instrument) { create_instrument }
  around { |e| travel_to(Time.zone.local(2026,9,25,12)) { e.run } }
  def event(**attrs)
    instrument.signals.create!({kind:'volume',episode_direction:'buy',title:'Event',event_key:SecureRandom.uuid,occurred_at:Time.current}.merge(attrs))
  end
  def rows(**opts)
    DailySignalStatistics.call(date:Date.current,horizon:15,**opts).index_by { |r| r[:key] }
  end
  it 'separates filtered and silent experiment cohorts from control' do
    event;event(research_only:true)
    event(kind:'reversal',research_only:true,experiment:'context_5m_v3',reversal_status:'confirmed',details:{direction:'up'})
    event(kind:'reversal_structure',research_only:true,experiment:'structure_v1',details:{direction:'up'})
    result=rows
    expect(result['volume'][:total]).to eq(2)
    expect(result['volume_visible'][:total]).to eq(1)
    expect(result['volume_suppressed'][:total]).to eq(1)
    expect(result['reversal'][:total]).to eq(0)
    expect(result['confirmation'][:total]).to eq(0)
    expect(result['context_confirmation'][:total]).to eq(1)
    expect(result['structure'][:total]).to eq(1)
  end
  it 'selects non-overlapping observations before looking at future availability' do
    event
    travel 2.minutes
    second=event;second.reaction.update!(results:{'15'=>{status:'measured',candles:15,change_percent:1}})
    travel 13.minutes
    event
    expect(rows(non_overlapping:true)['volume']).to include(total:2,overlapping:1,pending:2,measured:0)
    expect(rows['volume']).to include(total:3,overlapping:0,measured:1)
  end
  it 'counts a neutral outcome separately from sign-only accuracy' do
    [0.1,0.2,-0.2].each { |change| event.reaction.update!(results:{'15'=>{status:'measured',candles:15,change_percent:change}}) }
    expect(rows['volume']).to include(positive:2,negative:1,neutral:1,meaningful_positive:1,meaningful_negative:1)
  end
end
