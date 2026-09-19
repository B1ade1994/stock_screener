class AddAssessmentToPriceLevels < ActiveRecord::Migration[8.1]
  def change
    add_column :price_levels, :assessment, :jsonb, null: false, default: {}
  end
end
