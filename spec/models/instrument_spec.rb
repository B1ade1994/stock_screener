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
end
