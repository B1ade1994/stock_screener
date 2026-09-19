class AddReferenceSourceToCandles < ActiveRecord::Migration[8.1]
  def change
    add_column :candles, :data_source, :string, default: "t_invest", null: false
    add_column :candles, :reference_volume, :bigint
    change_column_null :candles, :volume, true
  end
end
