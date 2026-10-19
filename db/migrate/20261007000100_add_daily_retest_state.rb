class AddDailyRetestState < ActiveRecord::Migration[8.1]
  def change
    add_column :instruments, :daily_retest_state, :jsonb, default: {}, null: false
  end
end
