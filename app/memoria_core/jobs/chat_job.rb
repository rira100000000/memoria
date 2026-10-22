# チャット応答を非同期で処理するジョブ
class ChatJob < ApplicationJob
  queue_as :default

  def perform(chat_result_id)
    chat_result = ChatResult.find(chat_result_id)
    chat_result.update!(status: "processing")

    character = chat_result.character
    user = chat_result.user
    session = ChatSession.find_or_create(character, user)
    result = session.send_message(chat_result.message)

    chat_result.complete!(result[:response], result[:usage])
  rescue => e
    Rails.logger.error("[ChatJob] Error for ChatResult##{chat_result_id}: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}")
    chat_result&.fail!(e.message) if chat_result&.persisted?
  end
end
