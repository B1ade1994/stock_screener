# Sensitivity assumptions in percent of the initial notional, not broker fills.
class SignalCosts
  FIELDS = %i[commission_per_side spread slippage_per_side].freeze
  attr_reader(*FIELDS)

  def initialize(commission_per_side: 0, spread: 0, slippage_per_side: 0)
    { commission_per_side: commission_per_side, spread: spread, slippage_per_side: slippage_per_side }.each do |field, input|
      value = BigDecimal(input.presence.to_s.presence || '0')
      raise ArgumentError, 'Издержки должны быть от 0 до 100%' unless value.finite? && value.between?(0, 100)
      instance_variable_set("@#{field}", value)
    end
  end

  def self.from_params(params)
    new(**FIELDS.to_h { |field| [field, params[field]] })
  end

  def round_trip_percent = (2 * commission_per_side + spread + 2 * slippage_per_side).to_f
  def configured? = round_trip_percent.positive?
  def to_params = FIELDS.to_h { |field| [field, public_send(field).to_s('F')] }
end
