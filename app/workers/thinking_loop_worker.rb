# キャラクター単位の思考ループ実行ワーカー
# Stage 1: TopicScannerでルールベースフィルタ（LLM不要）
# Stage 2: LLMで価値判定 → 応答生成 → MessageDispatcherで配信
class ThinkingLoopWorker
  include Sidekiq::Worker

  sidekiq_options queue: :low, retry: 1

  def perform(character_id)
    character = Character.find(character_id)
    user = character.user

    # バジェットチェック
    unless ApiBudget.can_spend?(user, "thinking_loop")
      Rails.logger.info("[ThinkingLoopWorker] Budget exceeded for Character##{character_id}, skipping")
      return
    end

    vault = MemoriaCore::VaultManager.new(character.vault_path)

    # Stage 1: ルールベースフィルタ
    scanner = MemoriaCore::TopicScanner.new(vault)
    candidates = scanner.scan
    return if candidates.empty?

    # 上位3トピックに絞る
    top_topics = candidates.first(3)

    # Stage 2: LLMで価値判定 + 応答生成
    tracker = build_usage_tracker(user, character)
    llm_client = LlmClient.new(usage_tracker: tracker)

    result = evaluate_and_generate(llm_client, character, vault, top_topics)
    return unless result

    # MessageDispatcherで配信
    dispatcher = MessageDispatcher.new(character)
    dispatcher.dispatch(
      result[:message],
      trigger_type: "thinking_loop",
      topic_tag: result[:topic_tag]
    )

    Rails.logger.info("[ThinkingLoopWorker] Character##{character_id} sent message about: #{result[:topic_tag]}")
  rescue => e
    Rails.logger.error("[ThinkingLoopWorker] Error: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}")
    raise
  end

  private

  def evaluate_and_generate(llm_client, character, vault, topics)
    topics_text = topics.map { |t|
      tpn_content = vault.read(t[:path])
      _, body = MemoriaCore::Frontmatter.parse(tpn_content) if tpn_content
      summary = body.to_s.slice(0, 300)
      "- #{t[:tag]} (スコア: #{t[:score]}, 理由: #{t[:reasons].join(', ')})\n  内容: #{summary}"
    }.join("\n\n")

    prompt = <<~PROMPT
      あなたは #{character.name} です。以下のキャラクター設定に従ってください。

      #{character.system_prompt}

      ---

      以下は、あなたの記憶の中で注目すべきトピックの一覧です。
      これらを見て、「今、ユーザーに自分から話しかける価値があるか」を判断してください。

      #{topics_text}

      以下のJSONで回答してください:
      ```json
      {
        "should_speak": true/false,
        "topic_tag": "選んだトピック名（should_speakがtrueの場合）",
        "reason": "話しかける/話しかけない理由",
        "message": "ユーザーへのメッセージ（should_speakがtrueの場合。自然な口調で）"
      }
      ```
      JSONのみを返してください。
    PROMPT

    result = llm_client.generate(prompt, tier: :light)
    parsed = parse_json_response(result[:text])
    return nil unless parsed && parsed["should_speak"]

    { message: parsed["message"], topic_tag: parsed["topic_tag"] }
  end

  def parse_json_response(text)
    json_match = text.match(/```json\s*(.*?)\s*```/m)
    json_str = json_match ? json_match[1] : text
    JSON.parse(json_str)
  rescue JSON::ParserError
    nil
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
