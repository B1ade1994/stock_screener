namespace :levels do
  desc "Rebuild ATR zones and assessments from saved candles without API calls or historical signals"
  task rebuild: :environment do
    Instrument.find_each do |instrument|
      %w[day week].each do |timeframe|
        instrument.with_lock do
          candles = instrument.candles.where(timeframe: timeframe).order(:time).to_a
          LevelBuilder.call(instrument: instrument, timeframe: timeframe, candles: candles)
        end
      end
    end
    puts "ATR zones rebuilt from saved candles"
  end
end
