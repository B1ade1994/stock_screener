class AddReversalDetection < ActiveRecord::Migration[8.1]
  def change
    add_column :instruments, :reversal_enabled, :boolean, default: true, null: false
    add_column :instruments, :last_reversal_minute_at, :datetime
    add_column :market_minutes, :high_price, :decimal, precision: 24, scale: 9
    add_column :market_minutes, :low_price, :decimal, precision: 24, scale: 9
    add_column :signals, :reversal_status, :string
    add_index :signals, [:instrument_id, :occurred_at], where: "kind = 'reversal'", name: 'index_signals_on_reversals'
  end
end
