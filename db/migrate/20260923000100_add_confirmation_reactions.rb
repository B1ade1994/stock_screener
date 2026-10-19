class AddConfirmationReactions < ActiveRecord::Migration[8.1]
  def change
    add_column :signals, :confirmed_at, :datetime
    add_index :signals, :confirmed_at
    add_column :signal_reactions, :phase, :string, null: false, default: 'initial'
    add_column :signal_reactions, :baseline, :jsonb, null: false, default: {}
    remove_index :signal_reactions, :signal_id
    add_index :signal_reactions, [:signal_id, :phase], unique: true
  end
end
