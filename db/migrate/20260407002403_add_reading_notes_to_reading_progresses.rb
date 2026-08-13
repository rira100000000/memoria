class AddReadingNotesToReadingProgresses < ActiveRecord::Migration[8.1]
  def change
    add_column :reading_progresses, :reading_notes, :text
  end
end
