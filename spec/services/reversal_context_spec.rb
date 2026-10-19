require 'rails_helper'
require_relative '../support/reversal_helpers'
RSpec.describe 'Aggregated reversal context' do
  include ReversalHelpers
  around { |e| travel_to(Time.zone.local(2026,9,25,14)) { e.run } }
  it 'keeps the experimental long context separate from sharp moves' do
    expect(Detectors::Reversal.evaluate(bars: reversal_bars, aggregated_context: true)).to be_nil
    expect(Detectors::Reversal.evaluate(bars: reversal_bars(minutes:60), aggregated_context:true)).to include(version:3,context_minutes:5,scenario:'sustained')
  end
  it 'detects long direction obscured by minute noise without changing the control rule' do
    bars = reversal_bars(minutes:60)
    bars.slice(20,60).each_with_index do |b,i|
      b.close_price += i.even? ? 0.04 : -0.04
      b.high_price = [b.open_price,b.close_price].max + 0.01
      b.low_price = [b.open_price,b.close_price].min - 0.01
    end
    # Keep the last impulse close and extreme unchanged for the rebound criteria.
    original = reversal_bars(minutes:60); bars[79] = original[79]
    expect(Detectors::Reversal.evaluate(bars:bars)).to be_nil
    expect(Detectors::Reversal.evaluate(bars:bars,aggregated_context:true)).to include(impulse_minutes:60)
  end
  it 'creates a silent independent candidate and preserves baseline candidate tracking' do
    instrument=create_instrument
    bars=reversal_bars(minutes:60)
    bars.each { |b| b.instrument=instrument;b.save!;ReversalMinute.record_stream(instrument,b) }
    ReversalTracker.process(instrument,bars.last)
    expect(instrument.signals.visible.count).to eq(1)
    expect(instrument.signals.where(experiment:'context_5m_v3').sole).to have_attributes(research_only:true,reversal_status:'possible')
    expect(SignalReaction.count).to eq(2)
    ReversalTracker.process(instrument,bars.last,recheck:true)
    expect(instrument.signals.count).to eq(2)
  end
end
