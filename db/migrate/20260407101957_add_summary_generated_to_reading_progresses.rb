class AddSummaryGeneratedToReadingProgresses < ActiveRecord::Migration[8.1]
  def change
    add_column :reading_progresses, :summary_generated, :boolean, default: false, null: false
  end
end
