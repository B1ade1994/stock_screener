class AddSignalQuality < ActiveRecord::Migration[8.1]
  def change
    add_column :instruments, :volume_noise_filter, :boolean, default: true, null: false
    add_column :instruments, :volume_min_change_percent, :decimal, precision: 8, scale: 4, default: 0.05, null: false
    add_column :signals, :research_only, :boolean, default: false, null: false
    add_column :signals, :experiment, :string
    add_index :signals, [:research_only, :id]
    add_column :signal_reactions, :session_results, :jsonb, default: {}, null: false
  end
end
