class AddReversalMinuteHistory < ActiveRecord::Migration[8.1]
  def change
    create_table :reversal_minutes do |t|
      t.references :instrument, null: false, foreign_key: true
      t.datetime :time, null: false
      %i[open_price high_price low_price close_price].each { |name| t.decimal name, precision: 24, scale: 9, null: false }
      t.bigint :volume, null: false
      t.string :data_source, null: false
      t.string :source_session
      t.index [:instrument_id, :time], unique: true
    end
    add_column :instruments, :reversal_history_checked_at, :datetime
    add_column :instruments, :reversal_history_error, :string
  end
end
