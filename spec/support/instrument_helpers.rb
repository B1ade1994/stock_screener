module InstrumentHelpers
  def create_instrument(**overrides)
    Instrument.create!({
      uid: SecureRandom.uuid,
      ticker: "TEST",
      name: "Test instrument",
      class_code: "TQBR",
      kind: "share",
      currency: "rub"
    }.merge(overrides))
  end
end
