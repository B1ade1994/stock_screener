module InstrumentHelpers
  def create_strong_level(instrument, **overrides)
    level = instrument.price_levels.create!({ price: 100, side: 'resistance', timeframe: 'day',
      source: 'automatic', touches: 2, assessment: { 'version' => Detectors::Levels::VERSION, 'score' => 30 } }.merge(overrides))
    [10, 20].each_with_index do |score, index|
      instrument.price_levels.create!(price: level.price + 100 * (index + 1), side: 'resistance',
        timeframe: level.timeframe, source: 'automatic', touches: 2, created_at: level.created_at,
        assessment: { 'version' => Detectors::Levels::VERSION, 'score' => score })
    end
    level
  end

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
