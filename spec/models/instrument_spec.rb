require "rails_helper"

RSpec.describe Instrument, type: :model do
  it "excludes expired futures from the watchlist" do
    future = create_instrument(kind: "futures", expiration_date: Date.yesterday)
    expect(described_class.watched).not_to include(future)
  end

  it "rejects an invalid volume multiplier" do
    instrument = create_instrument
    expect(instrument.update(volume_multiplier: 0)).to be false
    expect(instrument.errors[:volume_multiplier]).to be_present
  end

  it "appends new instruments after a custom order, including after deletion" do
    first = create_instrument(ticker: "ZZZ")
    second = create_instrument(ticker: "AAA")
    third = create_instrument(ticker: "MMM")
    third.move_in_list!(target_id: first.id, placement: "before")
    first.destroy!
    added = create_instrument(ticker: "000")
    expect(described_class.in_display_order.ids).to eq([third.id, second.id, added.id])
    expect(described_class.distinct.count(:position)).to eq(described_class.count)
  end

  it "does not change the collector's ordered watchlist when moving rows" do
    first = create_instrument
    second = create_instrument
    subscription_ids = described_class.watched.order(:id).pluck(:uid)
    second.move_in_list!(target_id: first.id, placement: "before")
    expect(described_class.in_display_order.ids).to eq([second.id, first.id])
    expect(described_class.watched.order(:id).pluck(:uid)).to eq(subscription_ids)
  end

end
