class CreateChatResults < ActiveRecord::Migration[8.1]
  def change
    create_table :chat_results do |t|
      t.string :job_id, null: false
      t.references :user, null: false, foreign_key: true
      t.references :character, null: false, foreign_key: true
      t.string :status, null: false, default: "pending"
      t.text :message, null: false
      t.text :response
      t.jsonb :usage
      t.text :error_message
      t.datetime :completed_at

      t.timestamps
    end
    add_index :chat_results, :job_id, unique: true
    add_index :chat_results, :status
  end
end
