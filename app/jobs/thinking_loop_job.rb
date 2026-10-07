# AIの自発的思考を実行するジョブ
# AI自身がスケジュールを管理するイベント駆動型
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

      unless ApiBudget.can_spend?(character.user, "thinking_loop")
        Rails.logger.info("[ThinkingLoopJob] Budget exceeded for Character##{character_id}")
        return
      end

      think(character)
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

    unless ApiBudget.can_spend?(character.user, "thinking_loop")
      Rails.logger.info("[ThinkingLoopJob] Budget exceeded for Character##{character.id}")
      notify_failure(character, wakeup, due_at, "今日のAPI予算を使い切っていたため、動けませんでした。")
      return
    end

    attempts = 0
    begin
      attempts += 1
      think(character, wakeup: wakeup, due_at: due_at)
    rescue => e
      Rails.logger.error("[ThinkingLoopJob] Wakeup##{wakeup.id} attempt #{attempts} failed: #{e.message}\n#{e.backtrace&.first(10)&.join("\n")}")
      if attempts < WAKEUP_ATTEMPTS
        sleep(WAKEUP_RETRY_WAIT)
        retry
      end
      notify_failure(character, wakeup, due_at, "エラーで実行できませんでした（#{e.class}: #{e.message.to_s.truncate(120)}）。")
    end
  end

  def think(character, wakeup: nil, due_at: nil)
    core = MemoriaCore::Core.new(character.vault_path)
    health = Thinking::ThoughtHealthMonitor.report(core)

    # Step 0: 今の状況を集める（スケジュールの目的も含める）
    snapshot = Thinking::SnapshotBuilder.build(core, character, health)
    snapshot += wakeup_context(wakeup, due_at) if wakeup

    # Step 1-2: 思考の実行
    tracker = build_usage_tracker(character.user, character)
    llm_client = LlmClient.new(usage_tracker: tracker)

    result = Thinking::Thinker.run(
      snapshot: snapshot,
      character: character,
      core: core,
      health: health,
      llm_client: llm_client
    )

    # Step 3: 体験をmemoria-coreに記憶として渡す（記憶に残さない予定は省く）
    save_as_memory(core, character, result, llm_client) unless wakeup && !wakeup.remember

    # Step 4: ユーザーへの発話
    # 通常はAIが共有したいと判断した場合のみ。「伝える」予定は必ず送る
    message = result.share_message.presence
    if message.nil? && wakeup&.action == "share"
      message = result.summary.presence ||
        "⚠️ memoria: 予定「#{wakeup.purpose}」は実行しましたが、伝える内容が空でした。"
    end
    MessageDispatcher.dispatch(character, message) if message

    Rails.logger.info("[ThinkingLoopJob] Character##{character.id} completed. Summary: #{result.summary}")
  end

  def wakeup_context(wakeup, due_at)
    text = +"\n\n今回起きた理由: #{wakeup.purpose}"
    text << "\n予定していた行動: #{wakeup.action}" if wakeup.action.present?
    text << "\nこれは繰り返しの予定です（#{wakeup.recurrence}）。" if wakeup.recurring?
    if wakeup.action == "share"
      text << "\nこの予定ではマスターに必ず伝えることになっています。share_message に伝える内容を書いてください。"
    end
    late = Time.current - due_at
    if late > 5.minutes
      text << "\n予定の#{format_time(due_at)}より#{(late / 60).round}分遅れて起きました（サーバが止まっていた可能性があります）。"
    end
    text
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


  def save_as_memory(core, character, result, llm_client)
    conversation_text = result.to_conversation_text
    return if conversation_text.strip.empty?

    # FL(FullLog)は常に保存
    fl_store = core.fl_store
    fl_path = fl_store.create(character.name)
    fl_store.append(fl_path, conversation_text)

    fl_store.update_frontmatter(fl_path, {
      "source" => "autonomous",
      "participants" => result.participants.map(&:to_s),
    })

    # 読書が含まれるloopではSN生成を抑制（感想はReadingProgressに蓄積済み）
    if result.reading_occurred
      generate_reading_summary_if_completed(character, llm_client, core)
      return
    end

    # 読書を含まないloopは従来通りSN生成
    service = ReflectionService.new(character, llm_client: llm_client)
    reflection = service.generate(
      conversation_text: conversation_text,
      full_log_ref: File.basename(fl_path),
      timestamp: Time.now.strftime("%Y%m%d%H%M"),
    )

    process_reflection(reflection, core, character) if reflection
  end

  def process_reflection(reflection, core, character)
    sn_content = core.vault.read(reflection[:file_path])
    if sn_content
      fm, body = MemoriaCore::Frontmatter.parse(sn_content)
      if fm
        fm["source"] = "autonomous"
        core.vault.write(reflection[:file_path], MemoriaCore::Frontmatter.build(fm, body))
      end
    end

    TagProfilingJob.perform_later(character.id, reflection[:file_path])
  end

  def generate_reading_summary_if_completed(character, llm_client, core)
    completed = ReadingProgress
      .where(character: character, status: "completed", summary_generated: false)
      .where.not(reading_notes: [nil, "", "[]"])
      .first
    return unless completed

    # 読書の掛け合いをFullLogに保存
    save_reading_log_as_fl(completed, core, character)

    # キャラクターのSN生成
    service = Reading::ReadingSummaryService.new(character, llm_client: llm_client)
    reflection = service.generate_for(completed)
    process_reflection(reflection, core, character) if reflection

    # トートのSN生成
    generate_companion_reading_summary(completed, llm_client)

    # 統合SN生成済みフラグ（reading_notesは保持）
    completed.update!(summary_generated: true)
  end

  def save_reading_log_as_fl(reading_progress, core, character)
    companion_name = character.reading_companion&.name || Reading::ReadingCompanion::NAME

    lines = ["読書記録: #{reading_progress.author}「#{reading_progress.title}」\n"]
    reading_progress.parsed_notes.each do |entry|
      case entry["type"]
      when "narration"
        lines << "【原文】\n#{entry["text"]}\n"
      when "dialogue"
        speaker = entry["speaker"] == "hal" ? character.name : companion_name
        lines << "#{speaker}: #{entry["text"]}\n"
      end
    end

    fl_store = core.fl_store
    fl_path = fl_store.create(character.name)
    fl_store.append(fl_path, lines.join("\n"))
    fl_store.update_frontmatter(fl_path, {
      "source" => "reading",
      "participants" => [character.name, companion_name],
      "work_title" => reading_progress.title,
      "work_author" => reading_progress.author,
    })
  end

  def generate_companion_reading_summary(completed, llm_client)
    tote = Reading::ReadingCompanion.find_character(for_character: completed.character)
    return unless tote

    service = Reading::ReadingSummaryService.new(tote, llm_client: llm_client)
    reflection = service.generate_companion_summary_for(completed, reader_name: completed.character.name)
    return unless reflection

    tote_core = MemoriaCore::Core.new(tote.vault_path)
    process_reflection(reflection, tote_core, tote)
  rescue => e
    Rails.logger.warn("[ThinkingLoopJob] Companion summary failed: #{e.message}")
  end

  def build_usage_tracker(user, character)
    lambda { |model, usage|
      begin
        ApiUsageLog.record!(
          user: user,
          character: character,
          trigger_type: "thinking_loop",
          llm_model: model,
          usage: usage
        )
      rescue => e
        Rails.logger.warn("[ThinkingLoopJob] Usage tracking failed: #{e.message}")
      end
    }
  end
end
