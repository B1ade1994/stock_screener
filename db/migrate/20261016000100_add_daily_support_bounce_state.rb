class AddDailySupportBounceState < ActiveRecord::Migration[8.1]
  def change
    add_column :instruments, :daily_support_bounce_state, :jsonb, default: {}, null: false
  end
end
