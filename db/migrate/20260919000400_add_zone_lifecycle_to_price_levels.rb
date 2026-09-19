class AddZoneLifecycleToPriceLevels < ActiveRecord::Migration[8.1]
  def change
    add_column :price_levels, :lower_price, :decimal, precision: 24, scale: 9
    add_column :price_levels, :upper_price, :decimal, precision: 24, scale: 9
    add_column :price_levels, :atr, :decimal, precision: 24, scale: 9
    add_column :price_levels, :status, :string, null: false, default: "confirmed"
    add_column :price_levels, :breakout, :jsonb, null: false, default: {}
    add_column :price_levels, :evaluated_at, :datetime
    reversible do |dir|
      dir.up do
        execute <<~SQL
          UPDATE price_levels SET evaluated_at = (
            SELECT MAX(candles.time) FROM candles
            WHERE candles.instrument_id = price_levels.instrument_id
              AND candles.timeframe = price_levels.timeframe
          )
        SQL
      end
    end
  end
end
