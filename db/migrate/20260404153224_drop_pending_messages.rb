class DropPendingMessages < ActiveRecord::Migration[8.1]
  def change
    drop_table :pending_messages do |t|
      t.references :character, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.string :trigger_type, null: false
      t.text :content, null: false
      t.string :topic_tag
      t.string :status, null: false, default: "pending"
      t.datetime :delivered_at
      t.timestamps
    end

    remove_column :characters, :thinking_loop_interval_minutes, :integer, default: 60, null: false
  end
end
