class AddChartVisibleToPriceLevels < ActiveRecord::Migration[8.1]
  def change
    add_column :price_levels, :chart_visible, :boolean, default: true, null: false
  end
end
