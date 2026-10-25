# キャラクターを予定の時刻に起こすジョブ（予定なしの思考ループも含む）
# 起きて何を考えるかはアダプタ（MemoriaServer::Adapter#wake）が持つ。
# ここが持つのは、予定を進めること、失敗を黙らせないこと、伝えたいことを連絡手段に送ること
class ThinkingLoopJob < ApplicationJob
  queue_as :low

  # スケジュールなしの思考ループのみ対象。予定経由の実行は perform_wakeup 内で
  # 失敗を捕まえて知らせるので、ここまで例外が上がらない
  retry_on StandardError, wait: :polynomially_longer, attempts: 2

  # 予定経由の実行で、LLM呼び出し等が失敗したときにやり直す回数と間隔
  WAKEUP_ATTEMPTS = 2
  WAKEUP_RETRY_WAIT = 30.seconds

  # @param character_id [Integer]
  # @param wakeup_id [Integer, nil] ScheduledWakeupのID（スケジュール経由の場合）
  # @param scheduled_at [Integer, nil] 積んだ時点の予定時刻（epoch秒）。予定が繰り越された後の古いジョブを見分ける
  def perform(character_id, wakeup_id = nil, scheduled_at = nil)
    character = Character.find(character_id)

    if wakeup_id
      wakeup = ScheduledWakeup.find_by(id: wakeup_id)
      return unless wakeup&.status == "pending"  # キャンセル済み・承認待ちならスキップ
      return if scheduled_at && wakeup.scheduled_at.to_i != scheduled_at  # 繰り越し済みの古いジョブ

      perform_wakeup(character, wakeup)
    else
      # スケジュールなしの直接実行はthinking_loop_enabled必須
      return unless character.thinking_loop_enabled?

      begin
        wake(character)
      rescue MemoriaServer::WakeSkipped => e
        Rails.logger.info("[ThinkingLoopJob] Character##{character_id} did not wake: #{e.message}")
      end
    end
  rescue => e
    Rails.logger.error("[ThinkingLoopJob] Error: #{e.message}\n#{e.backtrace&.first(10)&.join("\n")}")
    raise
  end

  private

  def perform_wakeup(character, wakeup)
    due_at = wakeup.scheduled_at

    # 繰り返しの予定は、実行より先に次の回を予約する（この回が失敗しても連鎖が切れないように）
    if wakeup.recurring?
      stale = wakeup.stale?
      wakeup.advance!
      if stale
        notify_failure(character, wakeup, due_at, "サーバが止まっていたため、この回は飛ばしました。次は#{format_time(wakeup.scheduled_at)}です。")
        return
      end
    else
      wakeup.execute!
    end

    attempts = 0
    begin
      attempts += 1
      wake(character, wakeup: wakeup, due_at: due_at)
    rescue MemoriaServer::WakeSkipped => e
      # やり直しても同じ結果になる（予算切れ、LLM が使えない等）。知らせて終える
      notify_failure(character, wakeup, due_at, e.message)
    rescue => e
      Rails.logger.error("[ThinkingLoopJob] Wakeup##{wakeup.id} attempt #{attempts} failed: #{e.message}\n#{e.backtrace&.first(10)&.join("\n")}")
      if attempts < WAKEUP_ATTEMPTS
        sleep(WAKEUP_RETRY_WAIT)
        retry
      end
      notify_failure(character, wakeup, due_at, "エラーで実行できませんでした（#{e.class}: #{e.message.to_s.truncate(120)}）。")
    end
  end

  def wake(character, wakeup: nil, due_at: nil)
    result = MemoriaServer.adapter.wake(character_id: character.id, wakeup: wakeup && wakeup_payload(wakeup, due_at))

    # 通常はキャラが伝えたいと判断した場合のみ。「伝える」予定は必ず送る
    message = result[:share_message].presence
    if message.nil? && wakeup&.action == "share"
      message = result[:summary].presence ||
        "⚠️ memoria: 予定「#{wakeup.purpose}」は実行しましたが、伝える内容が空でした。"
    end
    return unless message

    MessageDispatcher.dispatch(character, message)
    record_outgoing(character, message) unless result[:recorded]
  end

  def wakeup_payload(wakeup, due_at)
    {
      id: wakeup.id,
      purpose: wakeup.purpose,
      action: wakeup.action,
      recurrence: wakeup.recurrence,
      due_at: due_at,
      remember: wakeup.remember,
    }
  end

  # 送った連絡を会話の履歴に入れる。失敗しても連絡は届いているので、止めない
  def record_outgoing(character, message)
    MemoriaServer.adapter.record_outgoing(character_id: character.id, text: message)
  rescue => e
    Rails.logger.warn("[ThinkingLoopJob] Could not add the message to the chat: #{e.message}")
  end

  # 黙って止まらないように、知らせるべき予定の失敗・スキップは連絡手段に送る
  def notify_failure(character, wakeup, due_at, reason)
    Rails.logger.warn("[ThinkingLoopJob] Wakeup##{wakeup.id} not completed: #{reason}")
    return unless wakeup.notify_on_failure?

    MessageDispatcher.dispatch(character, "⚠️ memoria: 予定「#{wakeup.purpose}」（#{format_time(due_at)}）について: #{reason}")
  end

  def format_time(time)
    time.in_time_zone(ScheduledWakeup::TIME_ZONE).strftime("%m/%d %H:%M")
  end
end
