class AddDeepModeToChatSessions < ActiveRecord::Migration[8.1]
  def change
    # 会話の途中で強いモデルに切り替えたか（claude -p バックエンドのとき）。セッションが閉じれば元に戻る
    add_column :chat_sessions, :deep_mode, :boolean, default: false, null: false
  end
end
