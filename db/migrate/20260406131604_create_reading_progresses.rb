class CreateReadingProgresses < ActiveRecord::Migration[8.1]
  def change
    add_column :characters, :reading_enabled, :boolean, default: false, null: false

    create_table :reading_progresses do |t|
      t.references :character, null: false, foreign_key: true
      t.string :work_id, null: false
      t.string :title, null: false
      t.string :author, null: false
      t.string :source_info
      t.text :cached_text
      t.integer :current_position, default: 0
      t.integer :total_length
      t.string :status, default: "reading", null: false
      t.timestamps
    end

    add_index :reading_progresses, [:character_id, :status]
    add_index :reading_progresses, [:character_id, :work_id], unique: true
  end
end
