client = TInvest::Client.new
found = client.search('SBER').find { |i| i['ticker'] == 'SBER' && i['classCode'] == 'TQBR' }
Instrument.transaction do
  item = Instrument.create!(client.instrument(found.fetch('uid')))
  RefreshHistoryJob.new.perform(item.id)
  item.reload
  raise item.history_error if item.history_error
  puts "History pipeline: #{item.candles.group(:timeframe).count}; levels: #{item.price_levels.group(:timeframe).count}"
  raise ActiveRecord::Rollback
end
