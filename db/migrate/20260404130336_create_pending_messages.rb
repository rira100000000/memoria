class CreatePendingMessages < ActiveRecord::Migration[8.1]
  def change
    create_table :pending_messages do |t|
      t.references :character, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.string :trigger_type, null: false  # thinking_loop, sleep_phase
      t.text :content, null: false
      t.string :topic_tag
      t.string :status, null: false, default: "pending"  # pending, delivered, read
      t.datetime :delivered_at

      t.timestamps
    end
    add_index :pending_messages, [:user_id, :status]
  end
end
