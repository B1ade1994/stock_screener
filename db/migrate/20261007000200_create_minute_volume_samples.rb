class CreateMinuteVolumeSamples < ActiveRecord::Migration[8.1]
  def change
    create_table :minute_volume_samples do |t|
      t.references :instrument, null: false, foreign_key: { on_delete: :cascade }
      t.datetime :time, null: false
      t.date :trading_date, null: false
      t.integer :minute_of_day, null: false
      t.string :day_type, null: false
      t.bigint :volume, null: false
      t.string :data_source, null: false
    end
    add_index :minute_volume_samples, [:instrument_id, :time], unique: true
    add_index :minute_volume_samples, [:instrument_id, :minute_of_day, :day_type, :trading_date], name: 'index_minute_volumes_on_seasonal_lookup'
    add_index :minute_volume_samples, :trading_date
    add_check_constraint :minute_volume_samples, 'volume >= 0', name: 'minute_volume_nonnegative'
    add_check_constraint :minute_volume_samples, 'minute_of_day BETWEEN 0 AND 1439', name: 'minute_volume_valid_minute'
  end
end
