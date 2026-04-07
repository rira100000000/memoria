class AddUniqueActiveSessionIndex < ActiveRecord::Migration[8.1]
  def change
    remove_index :chat_sessions, name: "index_chat_sessions_on_character_id_and_user_id_and_status"

    add_index :chat_sessions, [:character_id, :user_id],
              unique: true,
              where: "status = 'active'",
              name: "index_chat_sessions_unique_active"
  end
end
