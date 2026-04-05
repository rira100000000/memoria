# AIの自発的思考を実行するワーカー
# AI自身が次の起床時刻を決めるイベント駆動型
class ThinkingLoopWorker
  include Sidekiq::Worker

  sidekiq_options queue: :low, retry: 1

  MINIMUM_INTERVAL = 10.minutes
  MAXIMUM_INTERVAL = 24.hours

  def perform(character_id)
    character = Character.find(character_id)
    return unless character.thinking_loop_enabled?

    # バジェットチェック
    unless ApiBudget.can_spend?(character.user, "thinking_loop")
      Rails.logger.info("[ThinkingLoopWorker] Budget exceeded for Character##{character_id}, scheduling default wakeup")
      schedule_next_wakeup(character_id, nil)
      return
    end

    core = MemoriaCore::Core.new(character.vault_path)
    health = Thinking::ThoughtHealthMonitor.report(core)

    # Step 0: 今の状況を集める
    snapshot = Thinking::SnapshotBuilder.build(core, character, health)

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

    # Step 3: 体験をmemoria-coreに記憶として渡す
    save_as_memory(core, character, result, llm_client)

    # Step 4: ユーザーへの発話（AIが判断した場合のみ）
    # ユーザーへの発話（AIが共有したいと判断した場合のみ）
    if result.wants_to_share?
      MessageDispatcher.dispatch(character, result.share_message)
    end

    # Step 5: 次の起床をスケジュール
    schedule_next_wakeup(character_id, result.next_wakeup)

    Rails.logger.info("[ThinkingLoopWorker] Character##{character_id} completed. Summary: #{result.summary}")
  rescue => e
    Rails.logger.error("[ThinkingLoopWorker] Error: #{e.message}\n#{e.backtrace&.first(10)&.join("\n")}")
    # エラーでも次の起床はスケジュール（放置防止）
    schedule_next_wakeup(character_id, nil)
    raise
  end

  private

  def save_as_memory(core, character, result, llm_client)
    conversation_text = result.to_conversation_text
    return if conversation_text.strip.empty?

    # FLとして保存
    fl_store = core.fl_store
    fl_path = fl_store.create(character.name)
    fl_store.append(fl_path, conversation_text)

    # FL frontmatterにsource: autonomousを設定
    fl_store.update_frontmatter(fl_path, {
      "source" => "autonomous",
      "participants" => result.participants.map(&:to_s),
    })

    # SN生成（ReflectionService経由）
    service = ReflectionService.new(character, llm_client: llm_client)
    reflection = service.generate(
      conversation_text: conversation_text,
      full_log_ref: File.basename(fl_path),
      timestamp: Time.now.strftime("%Y%m%d%H%M")
    )

    if reflection
      # SN frontmatterにもsource: autonomousを追加
      sn_content = core.vault.read(reflection[:file_path])
      if sn_content
        fm, body = MemoriaCore::Frontmatter.parse(sn_content)
        if fm
          fm["source"] = "autonomous"
          core.vault.write(reflection[:file_path], MemoriaCore::Frontmatter.build(fm, body))
        end
      end

      # TagProfiling
      TagProfilingWorker.perform_async(character.id, reflection[:file_path])
    end
  end

  def schedule_next_wakeup(character_id, next_wakeup)
    unless next_wakeup
      # AIが指定しなかった場合、デフォルト3時間後
      ThinkingLoopWorker.perform_at(3.hours.from_now, character_id)
      return
    end

    clamped = next_wakeup.clamp(
      MINIMUM_INTERVAL.from_now,
      MAXIMUM_INTERVAL.from_now
    )
    ThinkingLoopWorker.perform_at(clamped, character_id)
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
        Rails.logger.warn("[ThinkingLoopWorker] Usage tracking failed: #{e.message}")
      end
    }
  end
end
