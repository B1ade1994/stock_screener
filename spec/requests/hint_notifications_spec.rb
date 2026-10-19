require 'rails_helper'

RSpec.describe 'Daily hint notifications', type: :request do
  around { |example| travel_to(Time.zone.local(2026, 10, 19, 12)) { example.run } }

  def cursor
    get latest_hints_path
    expect(response).to have_http_status(:ok)
    expect(response.headers['Cache-Control']).to include('no-store')
    response.parsed_body.fetch('latest_id')
  end

  def create_hint(instrument, kind: DailySupportBounceResearch::KIND)
    instrument.signals.create!(kind: kind, research_only: true, reversal_status: 'possible',
      event_key: "notification-#{instrument.signals.count}", title: 'Daily hint',
      occurred_at: 1.day.ago)
  end

  it 'ignores the event feed, archived minute ideas and other research' do
    instrument = create_instrument
    expect(cursor).to eq(0)
    %w[volume crossing reversal directional_hint volume_followthrough].each do |kind|
      instrument.signals.create!(kind: kind, title: kind, event_key: "silent-#{kind}", occurred_at: Time.current,
        research_only: %w[directional_hint volume_followthrough].include?(kind))
    end
    expect(cursor).to eq(0)
  end

  it 'notifies on new candidates and retest ideas using registration time, not candle time' do
    instrument = create_instrument
    bounce = create_hint(instrument)
    first_cursor = cursor
    expect(first_cursor).to eq((bounce.created_at.to_r * 1_000_000).to_i)
    expect(first_cursor).to be_between(1, 9_007_199_254_740_991)
    travel 1.second
    create_hint(instrument, kind: DailyRetestResearch::KIND)
    expect(cursor).to be > first_cursor
  end

  it 'notifies on confirmation of an older candidate without repeating for outcome or status updates' do
    instrument = create_instrument
    older = create_hint(instrument)
    travel 1.second
    create_hint(instrument)
    before_confirmation = cursor
    travel 1.second
    older.update!(reversal_status: 'confirmed', confirmed_at: Time.current)
    confirmed_cursor = cursor
    expect(confirmed_cursor).to be > before_confirmation
    travel 1.second
    older.update!(details: { outcomes: { '1' => { status: 'measured' } } })
    expect(cursor).to eq(confirmed_cursor)
    older.update!(reversal_status: 'cancelled')
    expect(cursor).to eq(confirmed_cursor)
    older.update!(reversal_status: 'expired')
    expect(cursor).to eq(confirmed_cursor)
  end
end
