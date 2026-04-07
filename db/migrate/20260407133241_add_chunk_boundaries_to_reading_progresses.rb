class AddChunkBoundariesToReadingProgresses < ActiveRecord::Migration[8.1]
  def change
    add_column :reading_progresses, :chunk_boundaries, :text
  end
end
