class AddSignalEpisodesAndReactions < ActiveRecord::Migration[8.1]
  def change
    add_column :signals, :episode_direction, :string
    add_column :signals, :last_occurred_at, :datetime
    add_index :signals, [:instrument_id, :episode_direction, :occurred_at], name: "index_signals_on_episode_window"

    create_table :signal_reactions do |t|
      t.references :signal, null: false, index: { unique: true }, foreign_key: { to_table: :signals, on_delete: :cascade }
      t.datetime :reference_at, null: false
      t.decimal :reference_price, precision: 24, scale: 9
      t.jsonb :results, null: false, default: {}
      t.datetime :next_check_at
      t.string :last_error
      t.timestamps
    end
    add_index :signal_reactions, :next_check_at, where: "next_check_at IS NOT NULL"
  end
end
