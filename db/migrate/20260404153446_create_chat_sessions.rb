class CreateChatSessions < ActiveRecord::Migration[8.1]
  def change
    create_table :chat_sessions do |t|
      t.references :character, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.string :status, null: false, default: "active"   # active, closed
      t.jsonb :messages, null: false, default: []         # LLMに渡すcontents配列
      t.string :pending_timeout_job_id                    # Discord用タイムアウトジョブID
      t.string :full_log_path                             # ChatLoggerの現在のログパス
      t.datetime :last_message_at

      t.timestamps
    end
    add_index :chat_sessions, [:character_id, :user_id, :status]
  end
end
