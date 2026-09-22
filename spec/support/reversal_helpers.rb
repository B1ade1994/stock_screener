module ReversalHelpers
  def reversal_bars(direction: 'up', minutes: 5, at: Time.current.beginning_of_minute - 2.minutes)
    session = SecureRandom.uuid
    prices = Array.new(20) { [100.0, 100.0, 100.05, 99.95, 100] }
    price = 100.0
    step = minutes == 5 ? 0.2 : 1.2 / minutes
    minutes.times do
      closing = price - step
      prices << [price, closing, price + 0.01, closing - 0.01, 100]
      price = closing
    end
    3.times do
      closing = price + 0.12
      prices << [price, closing, closing + 0.01, price - 0.01, 200]
      price = closing
    end
    prices.each_with_index.map do |(opening, closing, high, low, volume), index|
      opening, closing, high, low = 200 - opening, 200 - closing, 200 - low, 200 - high if direction == 'down'
      MarketMinute.new(time: at - (prices.size - index - 1).minutes, session: session, complete: true,
        open_price: opening.round(6), close_price: closing.round(6), high_price: high.round(6), low_price: low.round(6),
        buy: volume / 2, sell: volume / 2, unknown: 0, trades: 10)
    end
  end
end
