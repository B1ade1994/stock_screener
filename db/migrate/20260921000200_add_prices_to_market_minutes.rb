class AddPricesToMarketMinutes < ActiveRecord::Migration[8.1]
  def change
    add_column :market_minutes, :open_price, :decimal, precision: 24, scale: 9
    add_column :market_minutes, :close_price, :decimal, precision: 24, scale: 9
  end
end
