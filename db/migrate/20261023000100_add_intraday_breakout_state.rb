class AddIntradayBreakoutState < ActiveRecord::Migration[8.1]
  def change
    add_column :instruments, :intraday_breakout_state, :jsonb, default: {}, null: false
  end
end
