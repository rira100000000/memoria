class RemoveReadingFromServer < ActiveRecord::Migration[8.1]
  # 読書はプラグイン（記録はキャラの vault のファイル）に移ったので、サーバの表と列を消す
  def up
    drop_table :reading_progresses
    remove_foreign_key :characters, column: :reading_companion_id
    remove_index :characters, :reading_companion_id
    remove_column :characters, :reading_companion_id
    remove_column :characters, :reading_enabled
  end

  def down
    add_column :characters, :reading_enabled, :boolean, default: false, null: false
    add_reference :characters, :reading_companion, foreign_key: { to_table: :characters }
    create_table :reading_progresses do |t|
      t.references :character, null: false, foreign_key: true
      t.string :work_id, null: false
      t.string :title, null: false
      t.string :author, null: false
      t.string :source_info
      t.text :cached_text
      t.integer :total_length
      t.integer :current_position, default: 0
      t.text :chunk_boundaries
      t.text :reading_notes
      t.boolean :summary_generated, default: false, null: false
      t.string :status, default: "reading", null: false
      t.timestamps
      t.index [:character_id, :status]
      t.index [:character_id, :work_id], unique: true
    end
  end
end
