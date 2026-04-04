class CreateCharacters < ActiveRecord::Migration[8.1]
  def change
    create_table :characters do |t|
      t.references :user, null: false, foreign_key: true
      t.string :name, null: false
      t.text :system_prompt
      t.string :vault_dir_name, null: false
      t.boolean :thinking_loop_enabled, default: false
      t.integer :thinking_loop_interval_minutes, default: 30

      t.timestamps
    end
  end
end
