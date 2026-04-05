# Discordの会話が一定時間途絶えた時に自動でサマリーノートを作成するワーカー
# メッセージ受信のたびにperform_inで再スケジュールされる
class ConversationTimeoutWorker
  include Sidekiq::Worker

  sidekiq_options queue: :default, retry: 1

  TIMEOUT_MINUTES = ENV.fetch("CONVERSATION_TIMEOUT_MINUTES", 30).to_i

  def perform(chat_session_record_id, expected_message_count)
    record = ChatSessionRecord.find_by(id: chat_session_record_id)
    return unless record&.active?

    # 新しいメッセージが来ていたら何もしない（タイマーは再スケジュール済みのはず）
    return if record.message_count != expected_message_count

    character = record.character
    session = ChatSession.new(character, record: record)
    reflection = session.reset!

    if reflection
      TagProfilingWorker.perform_async(character.id, reflection[:file_path])
      SleepPhaseWorker.perform_async(character.id, reflection[:full_log_path]) if reflection[:full_log_path]
    end

    Rails.logger.info("[ConversationTimeoutWorker] Auto-closed session ##{record.id} for Character##{character.id}")
  rescue => e
    Rails.logger.error("[ConversationTimeoutWorker] Error: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}")
  end
end
