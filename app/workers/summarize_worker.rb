# 会話ログからサマリーノート生成を非同期実行するワーカー
# ReflectionServiceを使い、完了後にTagProfiling + SleepPhaseをenqueue
class SummarizeWorker
  include Sidekiq::Worker

  sidekiq_options queue: :default, retry: 1

  def perform(chat_result_id)
    chat_result = ChatResult.find(chat_result_id)
    chat_result.update!(status: "processing")

    character = chat_result.character

    tracker = build_usage_tracker(character.user, character)
    llm_client = LlmClient.new(usage_tracker: tracker)

    service = ReflectionService.new(character, llm_client: llm_client)
    result = service.generate(
      conversation_text: chat_result.message,
      full_log_ref: chat_result.usage&.dig("full_log_ref"),
      timestamp: chat_result.usage&.dig("timestamp")
    )

    if result
      chat_result.complete!(result.to_json, {
        file_path: result[:file_path],
        base_name: result[:base_name],
        tags: result[:tags],
      })

      # 後続の非同期処理をenqueue
      TagProfilingWorker.perform_async(character.id, result[:file_path])
      if chat_result.usage&.dig("full_log_path")
        SleepPhaseWorker.perform_async(character.id, chat_result.usage["full_log_path"])
      end
    else
      chat_result.fail!("Reflection generation returned nil")
    end
  rescue => e
    Rails.logger.error("[SummarizeWorker] Error: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}")
    chat_result&.fail!(e.message) if chat_result&.persisted?
  end

  private

  def build_usage_tracker(user, character)
    lambda { |model, usage|
      begin
        ApiUsageLog.record!(
          user: user,
          character: character,
          trigger_type: "user_message",
          llm_model: model,
          usage: usage
        )
      rescue => e
        Rails.logger.warn("[SummarizeWorker] Usage tracking failed: #{e.message}")
      end
    }
  end
end
