client = TInvest::Client.new
shares = client.search('SBER')
puts "API search shares: #{shares.size} results"
share = shares.find { |item| item['ticker'] == 'SBER' && item['classCode'] == 'TQBR' }
if share
  details = client.instrument(share.fetch('uid'))
  puts "Resolved: #{details.slice(:ticker, :kind, :lot)}"
  puts "Completed daily candles: #{client.candles(share.fetch('uid'), 'day').size}"
end
futures = client.search('Si').select { |item| item['instrumentType'] == 'futures' }
puts "API search futures: #{futures.size} results"
if futures.any?
  details = client.instrument(futures.first.fetch('uid'))
  puts "Resolved future: #{details.slice(:ticker, :kind, :expiration_date)}"
end
