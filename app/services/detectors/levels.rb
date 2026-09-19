module Detectors
  class Levels
    # A swing is known only after two later, completed candles.
    # Two distinct swings within 0.3% define an automatic candidate zone.
    def self.candidates(candles)
      return [] if candles.size < 9
      result = []
      { "resistance" => :high, "support" => :low }.each do |side, field|
        pivots = (2...(candles.size - 2)).filter_map do |i|
          value = candles[i].public_send(field).to_f
          neighbors = [i - 2, i - 1, i + 1, i + 2].map { |j| candles[j].public_send(field).to_f }
          extreme = side == "resistance" ? neighbors.all? { |n| value > n } : neighbors.all? { |n| value < n }
          { price: value, index: i } if extreme && value.positive?
        end
        clusters = []
        pivots.each do |pivot|
          cluster = clusters.find { |items| (items.first[:price] - pivot[:price]).abs / items.first[:price] <= 0.003 }
          cluster ? cluster << pivot : clusters << [pivot]
        end
        clusters.select { |items| items.size >= 2 }.each do |items|
          result << { side: side, price: items.sum { |p| p[:price] } / items.size, touches: items.size }
        end
      end
      result.sort_by { |item| -item[:touches] }.first(12)
    end
    def self.crossed?(side:, price:, previous:, current:)
      return false if previous.nil? || current.nil?
      boundary = price.to_d * (side == "resistance" ? BigDecimal("1.001") : BigDecimal("0.999"))
      side == "resistance" ? previous.to_d <= boundary && current.to_d > boundary : previous.to_d >= boundary && current.to_d < boundary
    end
  end
end
