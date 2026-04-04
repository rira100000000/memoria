# Sidekiq-Schedulerから定期実行され、思考ループ有効なキャラクターごとに
# ThinkingLoopWorkerをenqueueするスケジューラ
class ThinkingLoopSchedulerWorker
  include Sidekiq::Worker

  sidekiq_options queue: :low, retry: 0

  def perform
    Character.thinking_loop_active.find_each do |character|
      next unless should_run?(character)

      ThinkingLoopWorker.perform_async(character.id)
    end
  end

  private

  # キャラクターのinterval設定に応じて実行判定
  # 直近のpending_messageの作成時刻からinterval分経過しているか
  def should_run?(character)
    interval = character.thinking_loop_interval_minutes
    last_message = character.pending_messages
      .where(trigger_type: "thinking_loop")
      .order(created_at: :desc)
      .first

    return true unless last_message
    last_message.created_at < interval.minutes.ago
  end
end
