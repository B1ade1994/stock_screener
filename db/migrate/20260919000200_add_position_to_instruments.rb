class AddPositionToInstruments < ActiveRecord::Migration[8.1]
  def up
    add_column :instruments, :position, :integer
    execute <<~SQL
      WITH ranked AS (
        SELECT id, ROW_NUMBER() OVER (ORDER BY ticker, id) - 1 AS position
        FROM instruments
      )
      UPDATE instruments SET position = ranked.position
      FROM ranked WHERE instruments.id = ranked.id
    SQL
    change_column_null :instruments, :position, false
    add_index :instruments, :position
  end

  def down
    remove_column :instruments, :position
  end
end
