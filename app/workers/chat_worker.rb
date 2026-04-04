# チャット応答を非同期で処理するワーカー
# 記憶検索 + LLM呼び出しをバックグラウンドで実行し、結果をchat_resultsに保存
class ChatWorker
  include Sidekiq::Worker

  sidekiq_options queue: :default, retry: 1

  def perform(chat_result_id)
    chat_result = ChatResult.find(chat_result_id)
    chat_result.update!(status: "processing")

    character = chat_result.character
    session = find_or_create_session(chat_result.user_id, character)
    result = session.send_message(chat_result.message)

    chat_result.complete!(result[:response], result[:usage])
  rescue => e
    Rails.logger.error("[ChatWorker] Error for ChatResult##{chat_result_id}: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}")
    chat_result&.fail!(e.message) if chat_result&.persisted?
  end

  private

  def find_or_create_session(user_id, character)
    key = "chat_session_#{user_id}_#{character.id}"
    ChatSessionStore.instance.fetch(key) do
      ChatSession.new(character)
    end
  end
end
